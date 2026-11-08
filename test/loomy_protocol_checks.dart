import 'dart:convert';
import '../lib/loomy_protocol.dart';
import '../lib/model_provider.dart';

void check(bool ok, String why) {
  if (!ok) throw StateError(why);
}

Future<void> main() async {
  for (final status in [401, 403]) {
    final reply = await loomyFailure(
      ModelReply(
        status,
        'text/plain',
        Stream.error(StateError('unreadable native error')),
        retryAfterSeconds: 17,
      ),
    );
    check(
      reply.status == 401 &&
          reply.errorCode == 'authentication_required' &&
          reply.retryAfterSeconds == 17,
      'Loomy authorization refusal lost re-login meaning',
    );
    await reply.body.drain<void>();
  }
  for (final status in [400, 413, 422]) {
    final reply = await loomyFailure(
      ModelReply(
        status,
        'application/json',
        Stream.value(utf8.encode('{"message":"内容太长了"}')),
        retryAfterSeconds: 29,
      ),
    );
    check(
      reply.status == status &&
          reply.errorCode == 'context_length_exceeded' &&
          reply.retryAfterSeconds == 29,
      'Loomy overlength response lost context meaning or wait',
    );
    await reply.body.drain<void>();
  }
  final ordinary = await loomyFailure(
    ModelReply(
      400,
      'text/plain',
      Stream.value(utf8.encode('another native error')),
    ),
  );
  check(
    ordinary.errorCode == null &&
        await utf8.decoder.bind(ordinary.body).join() == 'another native error',
    'unrelated Loomy error was misclassified',
  );
  final body = <String, dynamic>{
    'model': 'deepseek-v4-flash-0731',
    'reasoning_effort': 'max',
    'messages': [
      {'role': 'system', 'content': 'Keep system.'},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '中文 image'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,QUJD'},
          },
        ],
      },
    ],
  };
  final original = jsonEncode(body);
  final wire = loomyRequest(body);
  check(
    wire['reasoning_effort'] == 'high' &&
        wire['messages'][0]['content'] == 'Keep system.' &&
        wire['messages'][1]['content'].length == 1 &&
        wire['messages'][1]['content'][0]['text'] ==
            '中文 image\n<image_base64>data:image/png;base64,QUJD</image_base64>',
    'legacy Loomy DeepSeek image/effort contract not applied',
  );
  check(jsonEncode(body) == original, 'caller request mutated');
  final modern = loomyRequest({...body, 'model': 'DeepSeek-V4.1-Flash'});
  check(
    modern['messages'][1]['content'][1]['type'] == 'image_url',
    'modern DeepSeek image was rewritten into unsupported text',
  );
  final off = loomyRequest({...body, 'reasoning_effort': 'none'});
  check(
    !off.containsKey('reasoning_effort'),
    'disabled vendor reasoning was enabled',
  );
  var rejected = false;
  try {
    loomyRequest({...body, 'reasoning_effort': 'unknown'});
  } on ModelServiceFailure {
    rejected = true;
  }
  check(rejected, 'unknown effort silently turned off reasoning');
  print(
    'PASS Loomy native effort and version-specific image encoding without mutation',
  );
}
