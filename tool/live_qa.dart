import 'dart:io';

import 'package:cursor_chat/api/cursor_api.dart';
import 'package:cursor_chat/title.dart';
import 'package:uuid/uuid.dart';

/// Multi-round live smoke using the same client as the app.
/// Requires CURSOR_API_KEY. Does not print the key.
void main() async {
  final key = Platform.environment['CURSOR_API_KEY']?.trim() ?? '';
  if (key.isEmpty) {
    stderr.writeln('SKIP: CURSOR_API_KEY not set');
    exit(2);
  }

  final issues = <String>[];
  void issue(String chat, String msg) {
    final line = '[$chat] $msg';
    issues.add(line);
    stdout.writeln('  ISSUE: $line');
  }

  stdout.writeln('== title freeze ==');
  const sampleTurns = [
    '分数除法为啥要颠倒相乘？用两三句话讲。',
    '那小数除法呢',
    '我想要 更短的总结',
  ];
  var frozen = '新对话';
  for (final q in sampleTurns) {
    if (frozen == '新对话') frozen = conversationTitle(q);
  }
  stdout.writeln('  frozen=$frozen last=${conversationTitle(sampleTurns.last)}');
  if (frozen != '分数除法颠倒相乘的原因') {
    issue('title', 'first-turn title drifted: $frozen');
  }
  if (frozen == conversationTitle(sampleTurns.last)) {
    issue('title', 'follow-up overwrote sidebar title');
  }

  final api = CursorApi(apiKey: key);
  stdout.writeln('\n== models ==');
  final models = await api.listModels();
  String modelId = models.first.id;
  for (final m in models) {
    if (m.id == 'composer-2.5' || m.id == 'composer-2') {
      modelId = m.id;
      break;
    }
  }
  stdout.writeln('  count=${models.length} using $modelId');

  Future<void> runChat(
    String name,
    List<String> turns, {
    bool restream = false,
    List<String> mustMention = const [],
  }) async {
    stdout.writeln('\n== chat: $name (${turns.length} turns) ==');
    String? agentId;
    String? sidebar;
    final replies = <String>[];
    for (var i = 0; i < turns.length; i++) {
      final q = turns[i];
      sidebar ??= conversationTitle(q);
      stdout.writeln('  turn ${i + 1}/${turns.length} sidebar=$sidebar');
      stdout.writeln('  ask: $q');
      final text = i == 0
          ? '$kFirstTurnPrefix${recencyPreamble()}$q'
          : '${recencyPreamble(followUp: true)}$q';
      final sw = Stopwatch()..start();
      try {
        late final String runId;
        if (agentId == null) {
          final created = await api.createAgent(
            text: text,
            modelId: modelId,
            modelParams: const [
              {'id': 'fast', 'value': 'true'},
            ],
            name: sidebar,
            agentId: 'bc-${const Uuid().v4()}',
          );
          agentId = created.agentId;
          runId = created.runId;
          stdout.writeln(
            '  created ${_short(agentId)} run=${_short(runId)} '
            '${sw.elapsedMilliseconds}ms',
          );
        } else {
          runId = await api.createRun(agentId: agentId, text: text);
          stdout.writeln(
            '  follow-up ${_short(runId)} ${sw.elapsedMilliseconds}ms',
          );
        }
        final reply = await api.streamRun(
          agentId: agentId,
          runId: runId,
          onDelta: (_) {},
        );
        sw.stop();
        replies.add(reply);
        stdout.writeln(
          '  reply ${sw.elapsedMilliseconds}ms len=${reply.length}',
        );
        stdout.writeln('  preview: ${_preview(reply)}');
        if (reply.trim().isEmpty) issue(name, 'empty reply on turn ${i + 1}');
        if (reply.contains('stream_unavailable') ||
            reply.contains('运行结束') ||
            reply.startsWith('出错了') ||
            reply.startsWith('Cursor API')) {
          issue(name, 'error leaked into reply on turn ${i + 1}');
        }
        if (i == 0 && restream) {
          final again = await api.streamRun(
            agentId: agentId,
            runId: runId,
            onDelta: (_) {},
          );
          if (again.contains('stream_unavailable') ||
              again.startsWith('Cursor API')) {
            issue(name, 're-stream leaked error');
          } else {
            stdout.writeln('  re-stream ok len=${again.length}');
          }
        }
      } catch (e) {
        sw.stop();
        issue(name, 'turn ${i + 1} threw after ${sw.elapsedMilliseconds}ms: $e');
      }
    }
    if (mustMention.isNotEmpty && replies.isNotEmpty) {
      final hay = replies.join('\n');
      final hit = mustMention.any(hay.contains);
      if (!hit) {
        issue(name, 'replies missed expected context $mustMention');
      }
    }
  }

  await runChat('math', [
    '分数除法为啥要颠倒相乘？两三句话，不要代码。',
    '那小数除法要不要也颠倒？',
    '口算 1.2 ÷ 0.3 等于多少，只要结果和一句理由。',
    '用一句话总结倒数这件事。',
  ], mustMention: ['小数', '除']);
  await runChat('recency', [
    '现在 Python 最新稳定版版本号是多少？给官方来源。查不到就说不确定。',
    '它的发布日期是哪天？',
    '那和 3.13 比，当前 stable 到底是哪个？',
  ], restream: true);
  await runChat('rewrite', [
    '把这句话写客气一点：把报告今天下班前交给我。不要代码。',
    '再短一点，保留原意。',
    '再给一句英文。',
  ], mustMention: ['report', 'Report', 'please', 'Please', 'kindly']);
  await runChat('photo-style', [
    '假如照片里是：解方程 2x+3=11。不要猜图，就按这道题讲为啥先移项。',
    '那如果改成 2x-3=11 呢？只说差在哪。',
    '最后给 x 的值。',
  ], mustMention: ['移项', 'x', '7', '14']);

  stdout.writeln('\n== summary ==');
  stdout.writeln('issues=${issues.length}');
  for (final item in issues) {
    stdout.writeln('  - $item');
  }
  if (issues.isNotEmpty) {
    exit(1);
  }
}

String _short(String id) {
  if (id.length <= 12) return id;
  return '${id.substring(0, 12)}…';
}

String _preview(String text) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.length <= 220) return t;
  return '${t.substring(0, 220)}…';
}
