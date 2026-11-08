import 'dart:async';
import 'dart:convert';
import '../lib/model_service.dart';

void _ensure(bool value, String message) {
  if (!value) throw StateError(message);
}

class PoolProvider extends ModelProvider {
  PoolProvider(this.id, this.protocol);
  @override
  final String id;
  final ModelProtocol protocol;
  final registrations = {'a': 'registration-a', 'b': 'registration-b'};
  final calls = <(String, ModelProtocol, Map<String, dynamic>)>[];
  final events = StreamController<void>.broadcast(sync: true);
  var discoveries = 0;
  var status = 200;
  var transportFails = false;
  var disconnected = 0;
  Completer<void>? hold;
  @override
  String get name => 'Source $id';
  @override
  Set<ModelProtocol> get protocols => {protocol};
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<List<ModelAccount>> accounts() async => [
    for (final entry in registrations.entries)
      ModelAccount(
        entry.key,
        'Account ${entry.key}',
        registrationId: entry.value,
      ),
  ];
  @override
  Future<ModelCatalog> discoverModels(String accountId) async {
    discoveries++;
    return ModelCatalog(
      registrationId: registrations[accountId]!,
      models: [
        ModelDefinition('shared', protocol: protocol),
        ModelDefinition('only-$accountId', protocol: protocol),
      ],
    );
  }

  @override
  Future<void> dispatch(
    String accountId,
    String registrationId,
    ModelProtocol protocol,
    Map<String, dynamic> body,
    Future<void> Function(ModelReply) consume, {
    required bool Function() isCurrent,
    required Future<void> cancelled,
  }) async {
    _ensure(
      registrations[accountId] == registrationId,
      'wrong account incarnation',
    );
    if (!isCurrent()) throw const ModelServiceFailure('account_unavailable');
    calls.add((accountId, protocol, body));
    if (transportFails) throw StateError('private synthetic transport data');
    await consume(
      ModelReply(
        status,
        'text/event-stream',
        (() async* {
          yield utf8.encode(
            'event: message_start\ndata: {"type":"message_start"}\n\n',
          );
          if (hold != null) await Future.any([hold!.future, cancelled]);
          if (!isCurrent())
            throw const ModelServiceFailure('account_unavailable');
          yield utf8.encode(
            'event: message_stop\ndata: {"type":"message_stop"}\n\n',
          );
        })(),
        cancel: () => disconnected++,
      ),
    );
  }
}
