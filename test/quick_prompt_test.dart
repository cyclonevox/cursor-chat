import 'package:cursor_chat/models/models.dart';
import 'package:cursor_chat/quick_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('allocateTopicCode is #T- plus six letters without I/O', () {
    final codes = <String>{};
    for (var i = 0; i < 20; i++) {
      final c = allocateTopicCode(codes);
      expect(isTopicCode(c), isTrue);
      expect(c.contains('I'), isFalse);
      expect(c.contains('O'), isFalse);
      codes.add(c);
    }
    expect(codes, hasLength(20));
  });

  test('follow-up turn is only the code and the question', () {
    final prompt = quickTopicTurnPrompt(
      topicCode: '#T-SJHXTH',
      question: '验证码怎么发？',
      messages: [
        ChatMessage(id: 'u1', role: 'user', text: '改登录'),
        ChatMessage(id: 'a1', role: 'assistant', text: '可以用邮箱。'),
        ChatMessage(id: 'u2', role: 'user', text: '验证码怎么发？'),
      ],
    );
    expect(prompt, startsWith('#T-SJHXTH\n'));
    expect(prompt, contains('用户：验证码怎么发？'));
    expect(prompt.contains('可以用邮箱'), isFalse);
    expect(prompt.contains('改登录'), isFalse);
    expect(prompt.contains('话题回溯'), isFalse);
    expect(prompt.contains(kQuickTopicReminder), isFalse);
  });

  test('replay dumps history and reminder', () {
    final prompt = quickTopicTurnPrompt(
      topicCode: '#T-SJHXTH',
      question: '验证码怎么发？',
      messages: [
        ChatMessage(id: 'u1', role: 'user', text: '改登录'),
        ChatMessage(id: 'a1', role: 'assistant', text: '可以用邮箱。'),
        ChatMessage(id: 'u2', role: 'user', text: '验证码怎么发？'),
      ],
      replay: true,
      remind: true,
    );
    expect(prompt, contains('#T-SJHXTH'));
    expect(prompt, contains('话题回溯'));
    expect(prompt, contains(kQuickTopicReminder));
    expect(prompt, contains('用户：改登录'));
    expect(prompt, contains('助手：可以用邮箱。'));
    expect(prompt, contains('用户最后一句：验证码怎么发？'));
    expect(prompt, contains('请直接回答'));
    expect(prompt.contains('必须按这个时间联网检索'), isFalse);
  });

  test('bootstrap states the #T- rule', () {
    final p = quickAgentBootstrapPrompt(warmup: true);
    expect(p, contains('#T-'));
    expect(p, contains('话题回溯'));
    expect(p, contains(kQuickAgentWarmup));
  });
}
