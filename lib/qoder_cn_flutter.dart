// Thin concrete platform wiring, not an alternative credential owner.
import 'package:flutter/services.dart';
import 'qoder_cn.dart';
class CnKeychainChannel implements CnNative {
 static const _channel=MethodChannel('com.sailingloong.loongpass/qoder-cn');
 @override Future<Map<String,dynamic>> call(String method,Map<String,dynamic> args)async {
  try {
   final result=await _channel.invokeMapMethod<String,dynamic>(method,args);
   if(result==null)throw const CnFailure('storage_unavailable');
   return result;
  }catch(_){throw const CnFailure('storage_unavailable');}
 }
}
QoderCn createQoderCn()=>QoderCn(native:CnKeychainChannel(),transport:CnHttp(),nowMs:()=>DateTime.now().millisecondsSinceEpoch);
