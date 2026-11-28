import 'package:flutter/services.dart';

import 'operation_log.dart';

const filesChannel = OperationMethodChannel('com.sailingloong.loongpass/files');

/// Captures only the method name and outcome, before the payload is encoded.
class OperationMethodChannel extends MethodChannel {
  const OperationMethodChannel(super.name);

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      OperationLog.trace(
        'native',
        '$name/$method',
        () => super.invokeMethod<T>(method, arguments),
      );
}
