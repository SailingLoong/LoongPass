// Thin concrete platform wiring, not an alternative credential owner.
import 'package:flutter/services.dart';
import 'qoder_device_accounts.dart';

class QoderFileChannel implements QoderNative {
  static const _channel = MethodChannel(
    'com.sailingloong.loongpass/qoder-accounts',
  );
  final QoderRegion region;
  QoderFileChannel(this.region);
  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(method, {
        'region': region.name,
        ...args,
      });
      if (result == null) throw const QoderAccountError('storage_unavailable');
      return result;
    } catch (_) {
      throw const QoderAccountError('storage_unavailable');
    }
  }
}

QoderDeviceAccounts createQoderDeviceAccounts({
  QoderRegion region = QoderRegion.cn,
}) => QoderDeviceAccounts(
  region: region,
  native: QoderFileChannel(region),
  transport: QoderHttp(region: region),
  nowMs: () => DateTime.now().millisecondsSinceEpoch,
);
