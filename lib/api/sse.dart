class SseEvent {
  const SseEvent({required this.event, required this.data, this.id});

  final String event;
  final String data;
  final String? id;
}

/// Incremental parser for text/event-stream blocks.
class SseParser {
  final StringBuffer _buf = StringBuffer();

  Iterable<SseEvent> add(String chunk) sync* {
    _buf.write(chunk.replaceAll('\r\n', '\n'));
    var all = _buf.toString();
    while (true) {
      final idx = all.indexOf('\n\n');
      if (idx < 0) break;
      final block = all.substring(0, idx);
      all = all.substring(idx + 2);
      final parsed = parseSseBlock(block);
      if (parsed != null) yield parsed;
    }
    _buf
      ..clear()
      ..write(all);
  }
}

SseEvent? parseSseBlock(String block) {
  if (block.trim().isEmpty) return null;
  String event = 'message';
  String? id;
  final dataLines = <String>[];
  for (final raw in block.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty || line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        dataLines.add(value);
      case 'id':
        id = value;
    }
  }
  if (dataLines.isEmpty && event == 'message') return null;
  return SseEvent(event: event, data: dataLines.join('\n'), id: id);
}
