import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'account_document_store.dart';
import 'legacy_account_sources.dart';
import 'native_account_document_store.dart';
import 'workbuddy_attempt_journal.dart';
import 'workbuddy_claim.dart';
import 'workbuddy_vault_flutter.dart';

LegacyAccountSources nativeLegacySources() {
  final vault = WorkBuddyVaultFlutter();
  return LegacyAccountSources(
    documents: {
      for (final scope in [
        'MiniMax-cn',
        'MiniMax-global',
        'TRAE-cn',
        'ZCode',
        'RewardChannels',
        'ModelService',
      ])
        scope: NativeAccountDocumentStore(scope),
      for (final region in ['cn', 'global'])
        'Qoder-$region': _QoderDocument(region),
    },
    readVault: () async => {
      for (final key in await vault.savedKeys()) key: await vault.read(key),
    },
    retireVault: (saved) async {
      for (final entry in saved.entries) {
        final current = await vault.read(entry.key);
        if (current?['state'] == 'revoked') continue;
        final original = entry.value as Map;
        if (current == null || current['revision'] != original['revision']) {
          throw StateError('Legacy WorkBuddy owner changed');
        }
        if (!await vault.compareExchange(entry.key, original['revision'], {
          'schema': 1,
          'revision': (original['revision'] as int) + 1,
          'state': 'revoked',
        }))
          throw StateError('Legacy WorkBuddy retirement was not saved');
      }
    },
    readWorkBuddyClaims: (saved) async {
      if (saved.isEmpty) return {};
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      final path = await channel.invokeMethod<String>(
        'prepareWorkBuddyJournal',
      );
      if (path == null || !Directory(path).isAbsolute)
        throw const FormatException('Invalid journal directory');
      final journal = WorkBuddyAttemptJournal(
        Directory(path),
        syncDirectory: () => channel.invokeMethod<void>('syncWorkBuddyJournal'),
        isCurrent: (_) => false,
      ); // Migration only reads the durable history.
      final result = <String, dynamic>{};
      for (final entry in saved.entries) {
        final row = entry.value as Map;
        if (row['state'] == 'revoked') continue;
        final subject = jsonEncode([row['domain'], row['uid']]);
        result[entry.key] = {
          'latest': _attempt(await journal.read(subject)),
          'successful': _attempt(await journal.latestSuccessful(subject)),
        };
      }
      return result;
    },
  );
}

Map<String, dynamic>? _attempt(WorkBuddyAttempt? value) => value == null
    ? null
    : {
        'revision': value.revision,
        'domain': value.subject.domain,
        'uid': value.subject.uid,
        'generation': value.subject.generation,
        'day': value.day,
        'before': value.before,
        'receipt': value.receipt.name,
        'expected': value.expected,
        'settled': value.settled.name,
        'credited': value.credited,
      };

class _QoderDocument implements AccountDocumentStore {
  _QoderDocument(this.region);
  final String region;
  static const _channel = MethodChannel(
    'com.sailingloong.loongpass/qoder-accounts',
  );
  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> arguments,
  ) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(method, {
      'region': region,
      ...arguments,
    });
    if (value == null) throw StateError('Legacy Qoder storage unavailable');
    return value;
  }

  @override
  String get identity => 'Qoder-$region';
  @override
  Future<AccountDocument> read() async {
    final value = await _call('read', {});
    return AccountDocument(value['revision'], jsonDecode(value['payload']));
  }

  @override
  Future<void> write(int expectedRevision, Map<String, dynamic> data) async {
    final value = await _call('compareAndSet', {
      'expectedRevision': expectedRevision,
      'payload': jsonEncode(data),
    });
    if (value['revision'] != expectedRevision + 1)
      throw StateError('Legacy Qoder retirement failed');
  }
}
