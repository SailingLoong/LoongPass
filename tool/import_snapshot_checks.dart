import 'dart:convert';
import 'dart:io';
import '../lib/qoder_pat_import.dart';
import '../lib/qoder_claim.dart';

void check(bool ok, String message) { if (!ok) throw StateError(message); }
Future<void> main() async {
  final temp = await Directory.systemTemp.createTemp('loongpass-snapshot-check-');
  final file = File('${temp.path}/synthetic.json');
  String document(String token) => jsonEncode({'database': {'providers': [
    for (final id in ['a', 'b']) {'id': id, 'app_type': 'codex',
      'settings_config': jsonEncode({'apiKey': '$token-$id'}),
      'meta': '{"providerType":"qoder_sdk"}'},
  ]}});
  try {
    await file.writeAsString(document('SYNTHETIC_BEFORE'));
    final candidate = await QoderPatImport.select(file, (ids) async {
      check(ids.join(',') == 'a,b', 'Unexpected selection catalog');
      await file.writeAsString(document('SYNTHETIC_AFTER'));
      return 'b';
    });
    check(candidate?.providerId == 'b', 'Wrong selected account');
    check(candidate!.useForVerification((v) => v == 'SYNTHETIC_BEFORE-b'),
      'Selected content drifted while choosing account');
    check(await file.readAsString() == document('SYNTHETIC_AFTER'), 'Source was mutated');
    print('PASS selected candidate stays bound to inspected document');
    check(await QoderPatImport.select(file, (_) async => null) == null,
      'Cancellation imported a candidate');
    print('PASS selection cancellation imports nothing');
    try {
      await QoderPatImport.select(file, (_) async => 'foreign');
      throw StateError('Foreign selection accepted');
    } on QoderFailure catch (error) {
      check(error.code == 'ProviderNotFound', 'Wrong sanitized rejection');
    }
    print('PASS foreign selection rejected');
    await file.writeAsString(jsonEncode({'id':'single',
      'settingsConfig':{'apiKey':'SYNTHETIC_SINGLE'},
      'meta':{'providerType':'qoder_sdk'}}));
    final single = await QoderPatImport.select(file,
      (_) async => throw StateError('Single provider unexpectedly prompted'));
    check(single?.providerId == 'single', 'Single provider not selected');
    print('PASS single provider selection avoids dialog');
    check(single.toString() == 'QoderPatCandidate(redacted)',
      'Candidate representation exposes contents');
    print('PASS candidate string is redacted');
    await file.writeAsString(document('SYNTHETIC_BEFORE'));
    final deleted = await QoderPatImport.select(file, (ids) async {
      await file.delete();
      return 'a';
    });
    check(deleted?.providerId == 'a' &&
      deleted!.useForVerification((v) => v == 'SYNTHETIC_BEFORE-a'),
      'Selection reopened deleted source');
    check(!await file.exists(), 'Selection recreated source');
    print('PASS selection uses no second file read or write');
    await file.writeAsString('SYNTHETIC_INVALID_DOCUMENT');
    try {
      await QoderPatImport.select(file,
        (_) async => throw StateError('Invalid document prompted'));
      throw StateError('Invalid document accepted');
    } on QoderFailure catch (error) {
      check(error.code == 'InvalidImport', 'Invalid input leaked error detail');
    }
    print('PASS malformed input fails before selection with fixed error');
  } finally { await temp.delete(recursive: true); }
}
