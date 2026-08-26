import 'package:cursor_chat/api/sse.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses assistant SSE block', () {
    final event = parseSseBlock('event: assistant\ndata: {"text":"你好"}');
    expect(event?.event, 'assistant');
    expect(event?.data, '{"text":"你好"}');
  });

  test('SseParser splits incremental chunks', () {
    final parser = SseParser();
    final first = parser
        .add('event: status\ndata: {"status":"RUNNING"}\n')
        .toList();
    expect(first, isEmpty);
    final second = parser
        .add('\nevent: assistant\ndata: {"text":"Hi"}\n\n')
        .toList();
    expect(second, hasLength(2));
    expect(second[0].event, 'status');
    expect(second[1].event, 'assistant');
  });
}
