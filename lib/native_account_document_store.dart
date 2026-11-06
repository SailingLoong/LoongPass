import 'dart:convert';
import 'package:flutter/services.dart';
import 'account_document_store.dart';

class NativeAccountDocumentStore implements AccountDocumentStore {
  @override
  final String identity;
  NativeAccountDocumentStore(this.identity);
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, Object?> args,
  ) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(method, {
        'scope': identity,
        ...args,
      });
      if (result == null) throw const FormatException();
      return result;
    } catch (_) {
      // Native errors and arguments can contain private state. Never forward.
      throw const AccountDocumentFailure();
    }
  }

  @override
  Future<AccountDocument> read() async {
    final value = await _call('readAccountDocument', {});
    try {
      final revision = value['revision'];
      final data = jsonDecode(value['payload'] as String);
      if (revision is! int || revision < 0 || data is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return AccountDocument(revision, data);
    } catch (_) {
      throw const AccountDocumentFailure();
    }
  }

  @override
  Future<void> write(int expectedRevision, Map<String, dynamic> data) async {
    final result = await _call('writeAccountDocument', {
      'expectedRevision': expectedRevision,
      'payload': jsonEncode(data),
    });
    if (result['revision'] != expectedRevision + 1) {
      throw const AccountDocumentFailure();
    }
  }
}

class AccountDocumentFailure implements Exception {
  const AccountDocumentFailure();
  @override
  String toString() => 'Account storage unavailable';
}
