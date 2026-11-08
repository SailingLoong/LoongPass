import '../lib/model_request_context.dart';

void check(bool ok, String why) {
  if (!ok) throw StateError(why);
}

void main() {
  final initial = <String, dynamic>{
    'messages': [
      {'role': 'user', 'content': 'hello'},
      {'role': 'system', 'content': 'Environment one'},
    ],
  };
  final first = ModelRequestContext.fromRequest(
    initial,
    session: 'client-session:worker-a',
    scope: 'caller-one',
    anthropicBeta: 'tools-2025-01-01',
  );
  final continuation = ModelRequestContext.fromRequest(
    {
      'messages': [
        ...initial['messages'] as List,
        {
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': 'call-1', 'name': 'echo', 'input': {}},
          ],
        },
        {'role': 'system', 'content': 'Environment two'},
        {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 'call-1', 'content': 'done'},
          ],
        },
      ],
    },
    session: 'client-session:worker-a',
    scope: 'caller-one',
  );
  check(
    first.hasSession && first.agentId == 'worker-a',
    'client identity lost',
  );
  check(
    first.sessionId == continuation.sessionId &&
        first.turnId == continuation.turnId &&
        first.requestId != continuation.requestId,
    'tool continuation must preserve session/turn and get a fresh request id',
  );
  final next = ModelRequestContext.fromRequest(
    {
      'messages': [
        ...initial['messages'] as List,
        {'role': 'assistant', 'content': 'Hello.'},
        {'role': 'user', 'content': 'hello'},
      ],
    },
    session: 'client-session:worker-a',
    scope: 'caller-one',
  );
  check(
    next.sessionId == first.sessionId && next.turnId != first.turnId,
    'a repeated user prompt is a new turn in the same session',
  );
  final account = first.forAccount('provider-one/account-one/registration-one');
  check(
    account.sessionId != first.sessionId &&
        account.sessionId ==
            continuation
                .forAccount('provider-one/account-one/registration-one')
                .sessionId &&
        account.sessionId !=
            first
                .forAccount('provider-one/account-two/registration-two')
                .sessionId &&
        account.anthropicBeta == 'tools-2025-01-01',
    'account context must isolate identity while preserving client options',
  );
  final otherCaller = ModelRequestContext.fromRequest(
    initial,
    session: 'client-session:worker-a',
    scope: 'caller-two',
  );
  check(
    otherCaller.sessionId != first.sessionId,
    'local grants share identity',
  );
  final unnamed = ModelRequestContext.fromRequest(initial);
  final unnamedAgain = ModelRequestContext.fromRequest(initial);
  check(
    !unnamed.hasSession && unnamed.sessionId != unnamedAgain.sessionId,
    'unidentified calls must not conflate identical opening text',
  );
  final uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[45][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  check(
    [
      first.sessionId,
      first.turnId,
      first.requestId,
      account.sessionId,
    ].every(uuid.hasMatch),
    'request identity must use valid UUIDs',
  );
  print(
    'PASS neutral client session, per-turn and account-scoped request identity',
  );
}
