import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_automatic.dart';
import '../lib/workbuddy_vault.dart';
import '../tool/workbuddy_multi_checks.dart' as fixture;
import '../tool/workbuddy_restore_checks.dart' as vault;

void main() {
  test(
    'periodic balance latency cannot starve the saved account reward schedule',
    () {
      fakeAsync((clock) {
        final server = fixture.Server('A'), attempts = fixture.Memory();
        final now = DateTime.utc(2026, 11, 5, 4);
        late WorkBuddyAutomatic automatic;
        final accounts = WorkBuddyAccounts(
          create: () => WorkBuddyAccountFlow(
            exchange: server,
            ownerGeneration: 'synthetic',
            isOwnerCurrent: () => true,
            store: attempts,
            now: () => now,
            readCompleteBalance: (subject) => Future.delayed(
              const Duration(seconds: 1),
              () => (
                subject: subject,
                totalRemaining: server.posts == 0 ? 10.0 : 30.0,
              ),
            ),
          ),
          onAccountReady: (id) => automatic.setEnabled(id, true),
        );
        automatic = WorkBuddyAutomatic(accounts);
        final saved = WorkBuddyVault(vault.Store(), now: () => now);
        try {
          unawaited(() async {
            final grant = (await accounts.beginAuthorization())!;
            await accounts.pollAndSave(grant.sessionId, saved);
          }());
          clock.flushMicrotasks();
          clock.elapse(const Duration(seconds: 45));
          expect(server.posts, 1);
          int statusReads() => server.requests
              .where((r) => r.uri.path.endsWith('checkin-activity-status'))
              .length;
          final startup = statusReads();
          clock.elapse(const Duration(minutes: 15));
          expect(statusReads(), greaterThan(startup));
          expect(server.posts, 1);
        } finally {
          automatic.close();
          accounts.close();
          saved.close();
        }
        expect(clock.periodicTimerCount, 0);
      });
    },
  );
}
