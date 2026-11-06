// Thin Flutter/native wiring. Credentials remain in memory; only attempt state
// uses the existing app-private append/flush/readback/native-sync approach.
import 'dart:io';
import 'package:flutter/services.dart';
import 'workbuddy_account_flow.dart';
import 'workbuddy_attempt_journal.dart';
import 'workbuddy_api.dart';

const _channel=MethodChannel('com.sailingloong.loongpass/files');

// No journal, Keychain or other client setup in the temporary identity mode.
Future<WorkBuddyAccountFlow> createWorkBuddyIdentityOwner()async{
  requireWorkBuddyIdentityAccess();
  return WorkBuddyAccountFlow.inMemory(identityValidationOnly:true);
}
Future<void> openWorkBuddyIdentityAuthorization(Uri uri)async{
  requireWorkBuddyIdentityAccess();
  await _openAuthorization(uri,'openWorkBuddyIdentityAuthorization');
}

Future<WorkBuddyAccountFlow> createWorkBuddyMemoryOwner() async {
  requireWorkBuddyProductionAccess();
  try {
    final path=await _channel.invokeMethod<Object?>('prepareWorkBuddyJournal');
    if(path is! String||!Directory(path).isAbsolute||path.contains('\u0000')) {
      throw const WorkBuddyApiFailure('JournalUnavailable',mayHaveBeenSent:false);
    }
    late final WorkBuddyAccountFlow flow;
    final journal=WorkBuddyAttemptJournal(Directory(path),
      syncDirectory:() async { await _channel.invokeMethod<void>('syncWorkBuddyJournal'); },
      isCurrent:(subject)=>flow.isCurrent(subject));
    flow=WorkBuddyAccountFlow.inMemory(store:journal);
    return flow;
  } catch(_) {
    throw const WorkBuddyApiFailure('JournalUnavailable',mayHaveBeenSent:false);
  }
}

Future<void> openWorkBuddyAuthorization(Uri uri) async {
  requireWorkBuddyProductionAccess();
  await _openAuthorization(uri,'openWorkBuddyAuthorization');
}
Future<void> _openAuthorization(Uri uri,String method)async{
  final state=uri.queryParametersAll['state'];
  if(uri.scheme!='https'||!['www.codebuddy.cn','www.workbuddy.cn'].contains(uri.host)||uri.port!=443||
      uri.userInfo.isNotEmpty||uri.hasFragment||state==null||state.length!=1||
      state.single.trim().isEmpty||state.single.length>4096||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(state.single)||
      uri.queryParameters.keys.any((key)=>key.toLowerCase().contains('token')||key.toLowerCase().contains('password'))) {
    throw const WorkBuddyApiFailure('InvalidAuthorization',mayHaveBeenSent:false);
  }
  try { await _channel.invokeMethod<void>(method,{'url':uri.toString()}); }
  catch(_) { throw const WorkBuddyApiFailure('BrowserUnavailable',mayHaveBeenSent:false); }
}
