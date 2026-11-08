// Loomy gateway adaptations from magpie-community/plugins packages/loomy (MIT).
// Shared Claude/Chat conversion happens before this supplier boundary.
import 'dart:convert';
import 'model_provider.dart';

Future<ModelReply> loomyFailure(ModelReply reply) async {
  String? code;
  var status = reply.status;
  List<int>? bytes;
  if (status == 401 || status == 403) {
    status = 401;
    code = 'authentication_required';
  } else if ({400, 413, 422}.contains(status)) {
    bytes = [];
    await for (final part in reply.body) {
      if (bytes.length + part.length > 2 * 1024 * 1024)
        throw const ModelServiceFailure('response_too_large');
      bytes.addAll(part);
    }
    if (RegExp(
      r'内容太长(了)?|内容过长',
    ).hasMatch(utf8.decode(bytes, allowMalformed: true)))
      code = 'context_length_exceeded';
  }
  if (code == null && bytes == null) return reply;
  return ModelReply(
    status,
    code == null ? reply.contentType : 'application/json',
    Stream.value(
      code == null
          ? bytes!
          : utf8.encode(
              jsonEncode({
                'error': {'type': code, 'message': code},
              }),
            ),
    ),
    cancel: reply.cancel,
    errorCode: code ?? reply.errorCode,
    retryAfterSeconds: reply.retryAfterSeconds,
    credentialRejected: reply.credentialRejected,
  );
}

Map<String, dynamic> loomyRequest(Map<String, dynamic> body) {
  final result = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
  String? effort(Object? value) => switch (value) {
    'minimal' || 'low' => 'low',
    'medium' => 'medium',
    'high' || 'xhigh' || 'max' => 'high',
    'none' || 'off' => null,
    _ => throw const ModelServiceFailure('unsupported_reasoning_effort'),
  };
  void fold(Map value, String key) {
    if (!value.containsKey(key)) return;
    final normalized = effort(value[key]);
    if (normalized == null) {
      value.remove(key);
    } else {
      value[key] = normalized;
    }
  }

  fold(result, 'reasoning_effort');
  if (result['reasoning'] is Map) fold(result['reasoning'], 'effort');
  final model = '${result['model']}'.toLowerCase();
  if (!model.contains('deepseek') ||
      RegExp(r'v4[.-]1(?![0-9])').hasMatch(model)) {
    return result;
  }
  for (final message in (result['messages'] as List? ?? const [])) {
    if (message is! Map || message['content'] is! List) continue;
    final content = message['content'] as List;
    for (var i = content.length - 1; i >= 0; i--) {
      final part = content[i];
      if (part is! Map || !{'image_url', 'input_image'}.contains(part['type']))
        continue;
      final image = part['image_url'];
      final url = image is Map ? image['url'] : image;
      if (url is! String || !url.startsWith('data:')) {
        throw const ModelServiceFailure('unsupported_image_source');
      }
      final tag = '<image_base64>$url</image_base64>';
      content.removeAt(i);
      if (i > 0 && content[i - 1] is Map && content[i - 1]['type'] == 'text') {
        content[i - 1]['text'] = '${content[i - 1]['text']}\n$tag';
      } else if (i < content.length &&
          content[i] is Map &&
          content[i]['type'] == 'text') {
        content[i]['text'] = '$tag\n${content[i]['text']}';
      } else {
        content.insert(i, {'type': 'text', 'text': tag});
      }
    }
  }
  return result;
}
