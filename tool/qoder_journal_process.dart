// Synthetic-only process probe, launched by the integration test.
import 'dart:async';
import 'dart:io';
import '../lib/qoder_claim.dart';
import '../lib/qoder_journal.dart';

Future<void> main(List<String> args) async {
  final hold = args[1] == 'hold';
  final journal = QoderAttemptJournal(
    Directory(args[0]),
    syncDirectory: () async {
      if (hold) {
        stdout.writeln('locked');
        await stdin.first;
      }
    },
  );
  try {
    final claimed = await journal.claim({
      'providerId': 'synthetic-provider',
      'uid': 'synthetic-uid',
      'generation': 'generation-1',
      'region': 'international',
      'campaignId': 'synthetic-daily',
      'campaignKey': 'synthetic-window',
      'startAt': 1793707100,
      'endAt': 1793710800,
    });
    stdout.writeln(claimed ? 'granted' : 'duplicate');
  } on QoderFailure catch (error) {
    stdout.writeln(error.code);
  }
}
