import 'dart:convert';
import 'model_provider.dart';

class ModelSseEvent {
  final String event, data;
  const ModelSseEvent(this.event, this.data);
  List<int> encode() => utf8.encode(
    '${event.isEmpty ? '' : 'event: $event\n'}${data.split('\n').map((line) => 'data: $line').join('\n')}\n\n',
  );
}

/// SSE fields are line based: comments and empty events are not data, CR/LF
/// variants are equivalent, and multiple data lines form one event.
Stream<ModelSseEvent> modelSseEvents(Stream<List<int>> body) async* {
  var event = '', size = 0;
  final data = <String>[];
  await for (final line
      in utf8.decoder.bind(body).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) yield ModelSseEvent(event, data.join('\n'));
      event = '';
      data.clear();
      size = 0;
      continue;
    }
    size += line.length;
    if (size > 2 * 1024 * 1024)
      throw const ModelServiceFailure('upstream_event_too_large');
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') event = value;
    if (field == 'data') data.add(value);
  }
  // A partial final event is not a complete server-sent event. Consumers must
  // observe their protocol's terminal event before accepting normal EOF.
}
