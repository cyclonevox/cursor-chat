import 'package:flutter_test/flutter_test.dart';
import 'package:cursor_chat/title.dart';

void main() {
  test('rejects internal agent names', () {
    expect(isUsableTitle('assistant response logic'), isFalse);
    expect(isUsableTitle('Tool Call Handler'), isFalse);
    expect(isUsableTitle('Rust 1.98 发布了吗'), isTrue);
  });

  test('falls back to user summary', () {
    expect(
      conversationTitle(
        '这题为啥要先通分？后面那步看不懂。',
        agentName: 'assistant response logic',
      ),
      '这题为啥要先通分',
    );
    expect(conversationTitle('（图片）'), '看图提问');
  });

  test('recency preamble includes local date', () {
    final now = DateTime.now();
    final preamble = recencyPreamble();
    expect(preamble, contains('当前时间：${now.year}-'));
    expect(preamble, contains('必须按这个时间检索最新来源'));
  });
}
