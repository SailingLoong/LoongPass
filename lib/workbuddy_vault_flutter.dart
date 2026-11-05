import 'package:flutter/services.dart';
import 'native_account_gate.dart';
import 'workbuddy_vault.dart';

// No production instance is created by the app. A synthetic transport may be
// injected by isolated probes; no user-selectable Keychain/path is exposed.
class WorkBuddyVaultFlutter implements WorkBuddyVaultStore {
 final Future<Object?> Function(String,Map<String,Object?>) _invoke;
 WorkBuddyVaultFlutter():_invoke=_production;
 WorkBuddyVaultFlutter.synthetic(this._invoke);
 static Future<Object?> _production(String method,Map<String,Object?> args)async{
  if(!workBuddyNativeAdapterValidated||!workBuddyPersistentAccessValidated)throw StateError('WorkBuddy persistent access unavailable');
  return const MethodChannel('com.sailingloong.loongpass/files').invokeMethod<Object?>(method,args);
 }
 Future<List<String>> savedKeys()async{
  final value=await _invoke('listWorkBuddyVaultKeys',{});
  if(value is! List||value.length>16||value.any((v)=>v is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(v)))throw const FormatException('Invalid saved account metadata');
  final keys=List<String>.from(value);if(keys.toSet().length!=keys.length)throw const FormatException('Duplicate saved account metadata');return List.unmodifiable(keys);
 }
 @override Future<Map<String,Object?>?> read(String key)async{
  final value=await _invoke('readWorkBuddyVault',{'key':key});
  if(value==null)return null;
  if(value is! Map)throw const FormatException('Invalid vault response');
  return Map<String,Object?>.from(value);
 }
 @override Future<bool> compareExchange(String key,int? expected,Map<String,Object?> value)async{
  final result=await _invoke('compareExchangeWorkBuddyVault',{'key':key,'expected':expected,'value':value});
  if(result is! bool)throw const FormatException('Invalid vault response');return result;
 }
}
