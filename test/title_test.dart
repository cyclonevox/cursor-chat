import 'package:cursor_chat/title.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects internal agent names', () {
    expect(isUsableTitle('assistant response logic'), isFalse);
    expect(isUsableTitle('Tool Call Handler'), isFalse);
    expect(isUsableTitle('thinking process'), isFalse);
    expect(isUsableTitle('Rust 1.98 发布了吗'), isTrue);
  });

  test('titles are topics, not the raw user question', () {
    const questions = [
      '这题为啥要先通分？',
      '今天是星期几',
      '分数除法为啥要颠倒相乘？用两三句话讲。',
      '什么是哈希碰撞',
      '牛顿第一定律是什么',
    ];
    for (final q in questions) {
      final title = conversationTitle(q);
      expect(title, isNot(q), reason: q);
      expect(title.contains('？'), isFalse, reason: title);
      expect(looksLikeQuestion(title), isFalse, reason: title);
    }
  });

  test('turns questions into short topics', () {
    const cases = <String, String>{
      '这题为啥要先通分？后面那步看不懂。': '先通分的原因',
      '用中文一两句话回答：现在（2026年8月）Rust 最新稳定版版本号是多少？': 'Rust 最新稳定版',
      '帮我看看这段报错怎么修': '这段报错的修法',
      '（图片）': '看图提问',
      '我想要 箭头函数写法': '箭头函数写法',
      '分数除法为啥要颠倒相乘？用两三句话讲。': '分数除法颠倒相乘的原因',
      '帮我看看这段 rust 报错：cannot borrow as mutable': '这段 rust 报错',
      '那小数除法呢': '小数除法',
      '请解释一下牛顿第一定律': '牛顿第一定律',
      '麻烦把这段话写客气一点': '把这段话写客气一点',
      '今天是星期几': '今天星期',
      '什么是哈希碰撞': '哈希碰撞',
      '牛顿第一定律是什么': '牛顿第一定律',
    };
    for (final e in cases.entries) {
      expect(conversationTitle(e.key), e.value, reason: e.key);
    }
    expect(
      conversationTitle('这题为啥要先通分？', agentName: 'assistant response logic'),
      '先通分的原因',
    );
  });

  test('first reply can refine the summary, follow-ups do not', () {
    const q = '什么是哈希碰撞';
    final afterReply = conversationTitle(
      q,
      assistantText: '哈希碰撞是指不同输入映射到同一哈希值。',
    );
    expect(afterReply, '哈希碰撞');
    expect(afterReply, isNot(q));

    const turns = [
      '分数除法为啥要颠倒相乘？用两三句话讲。',
      '那小数除法呢',
      '举个 1.2 ÷ 0.3 的例子',
      '我想要 更短的总结',
    ];
    var title = '新对话';
    for (final q in turns) {
      if (title == '新对话') title = conversationTitle(q);
    }
    expect(title, '分数除法颠倒相乘的原因');
    expect(title, isNot(conversationTitle(turns.last)));
  });

  test('recency preamble includes local date', () {
    final now = DateTime.now();
    final preamble = recencyPreamble();
    expect(preamble, contains('${now.year}-'));
    expect(preamble, contains('不要猜旧数据'));
    expect(recencyPreamble(followUp: true), contains('查不到就说不确定'));
  });
}
