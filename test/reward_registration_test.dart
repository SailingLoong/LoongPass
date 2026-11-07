import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../lib/managed_app.dart';
import '../lib/rewards/reward_accounts.dart';
import '../lib/rewards/reward_provider.dart';
import '../lib/rewards/reward_providers.dart';
import '../lib/ui_preferences.dart';
import 'reward_test_support.dart';

void main() {
  test(
    'new reward channels join the workspace without dropping saved app order',
    () async {
      final preferences = UiPreferences(
        read: () async =>
            '{"appOrder":["workbuddy","zcode","qoderCn","qoder","minimaxCn","minimax","traeCn"]}',
      );
      await preferences.load();
      expect(preferences.appOrder.take(7).map((app) => app.name), [
        'workbuddy',
        'zcode',
        'qoderCn',
        'qoder',
        'minimaxCn',
        'minimax',
        'traeCn',
      ]);
      expect(preferences.appOrder.skip(7).map((app) => app.name), [
        'loomy',
        'codex',
      ]);
      expect(
        ManagedApp.values.map((app) => app.name).toSet().length,
        ManagedApp.values.length,
      );
    },
  );

  test(
    'saved retired accounts never send automatic requests after upgrade',
    () async {
      final key = jsonEncode(['lobsterai', 'legacy-official-user']);
      final store = MemoryStore()
        ..value = {
          'version': 1,
          'accounts': {
            key: {
              'provider': 'lobsterai',
              'identity': 'legacy-official-user',
              'label': 'Retired account',
              'credentials': {
                'access_token': 'synthetic-legacy-access',
                'refresh_token': 'synthetic-legacy-refresh',
                'expires_at': '1800000000000',
                'uuid': 'synthetic-installation',
                'first_keyfrom': '100',
                'latest_keyfrom': '200',
                'user_id': 'synthetic-legacy-yid',
              },
              'automatic': true,
            },
          },
          'journals': {
            key: {
              '2026-11-07': {'state': 'unknown'},
            },
          },
        };
      final transport = _RecordingTransport();
      final owner = RewardAccounts(
        store: store,
        providers: rewardProviders,
        transportFor: (_) => transport,
        now: () => DateTime.utc(2026, 11, 7),
      );
      addTearDown(owner.dispose);

      await owner.restore();
      await owner.tick();

      expect(transport.requests, isEmpty);
      expect(store.revision, 0);
      expect(
        (store.value['journals'] as Map)[key]['2026-11-07']['state'],
        'unknown',
      );
    },
  );
}

class _RecordingTransport implements RewardTransport {
  final requests = <Uri>[];
  @override
  Future<RewardReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  }) async {
    requests.add(url);
    throw const RewardFailure('network_unavailable');
  }
}
