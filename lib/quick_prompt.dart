import 'dart:math';

import 'api/cursor_api.dart';
import 'models/models.dart';
import 'title.dart';

const kTopicCodePrefix = '#T-';
const kTopicCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ';

const kQuickAgentRules =
    '你会同时处理多个互不干扰的话题：\n'
    '- 每条用户消息第一行是话题编号，格式永远是 #T- 后跟 6 个大写字母，例如 #T-SJHXTH。'
    '只认这个编号，不要靠措辞或标题猜是不是同一题。\n'
    '- 编号不同就是不同话题。只根据当前这个编号回答，不要串题，除非用户明确要求对照。\n'
    '- 若程序在编号下一行写了「话题回溯：」，下面就是该编号的完整记录。'
    '按这份记录直接回答用户最后一句，必须给出用户能看见的文字，不要空回复，不要复述已经讲过的内容。\n';

const kQuickTopicReminder =
    '提醒：只认第一行 #T- 后跟 6 位字母的编号；编号不同不要串题。'
    '若有「话题回溯：」按其后记录直接回答最后一句，必须给出可见文字。';

const kQuickAgentWarmup = '（系统就绪。不要把这段当成话题，也不用对用户说话。）';

const kDefaultRotateAfter = 20;
const kDefaultRotateTokens = 80000;
const kDefaultRemindEvery = 8;

final _topicCodeRand = Random.secure();

String allocateTopicCode(Iterable<String> existing) {
  final taken = {for (final c in existing) c.toUpperCase()};
  for (var n = 0; n < 128; n++) {
    final buf = StringBuffer(kTopicCodePrefix);
    for (var i = 0; i < 6; i++) {
      buf.write(
        kTopicCodeAlphabet[_topicCodeRand.nextInt(kTopicCodeAlphabet.length)],
      );
    }
    final code = buf.toString();
    if (!taken.contains(code)) return code;
  }
  throw StateError('无法分配话题编号');
}

bool isTopicCode(String? raw) {
  if (raw == null || raw.length != 9 || !raw.startsWith(kTopicCodePrefix)) {
    return false;
  }
  for (var i = 3; i < 9; i++) {
    if (!kTopicCodeAlphabet.contains(raw[i])) return false;
  }
  return true;
}

String quickAgentBootstrapPrompt({bool warmup = false}) {
  final buf = StringBuffer()
    ..write(kFirstTurnPrefix)
    ..writeln(kQuickAgentRules.trim())
    ..writeln()
    ..write(recencyPreamble());
  if (warmup) buf.writeln(kQuickAgentWarmup);
  return buf.toString();
}

/// One user turn on the shared quick agent. [omitRecency] when this is appended
/// to a bootstrap prompt that already has the date line.
String quickTopicTurnPrompt({
  required String topicCode,
  required String question,
  required List<ChatMessage> messages,
  bool replay = false,
  bool remind = false,
  bool omitRecency = false,
}) {
  final buf = StringBuffer()..writeln(topicCode);
  if (replay) {
    buf.writeln(
      '话题回溯：这是同一话题换到当前助手后的后续。'
      '根据下面的上下文直接回答用户最后一句。必须给出可见文字，不要空回复，不要复述全文。',
    );
  }
  if (remind) buf.writeln(kQuickTopicReminder);
  buf.writeln();
  if (!omitRecency) {
    buf.write(recencyPreamble(followUp: true));
  }
  if (replay) {
    ChatMessage? lastUser;
    for (final m in messages.reversed) {
      if (!m.streaming && !m.queued && m.role == 'user') {
        lastUser = m;
        break;
      }
    }
    for (final m in messages) {
      if (identical(m, lastUser) || m.streaming || m.queued) continue;
      final t = m.text.trim();
      if (t.isEmpty || isFailedAssistantText(t)) continue;
      if (m.role == 'user') {
        buf.writeln('用户：$t');
      } else if (m.role == 'assistant') {
        buf.writeln('助手：${clipPromptHistory(t)}');
      }
      buf.writeln();
    }
    buf.writeln('用户最后一句：$question');
    buf.writeln('请直接回答。');
    return buf.toString();
  }
  buf.writeln('用户：$question');
  return buf.toString();
}

String clipPromptHistory(String text) {
  if (text.length <= 4000) return text;
  return '${text.substring(0, 4000)}…';
}

bool topicHasPriorTurns(List<ChatMessage> messages) {
  ChatMessage? lastUser;
  for (final m in messages.reversed) {
    if (!m.streaming && !m.queued && m.role == 'user') {
      lastUser = m;
      break;
    }
  }
  for (final m in messages) {
    if (identical(m, lastUser) || m.streaming || m.queued) continue;
    final t = m.text.trim();
    if (t.isEmpty || isFailedAssistantText(t)) continue;
    if (m.role == 'user' || m.role == 'assistant') return true;
  }
  return false;
}
