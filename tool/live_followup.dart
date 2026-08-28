import 'dart:convert';
import 'dart:io';

import 'package:cursor_chat/api/cursor_api.dart';
import 'package:cursor_chat/models/models.dart';
import 'package:uuid/uuid.dart';

/// Two-turn live check: first answer, then a clarifying follow-up.
/// Loads CURSOR_API_KEY or the Linux app prefs. Does not print the key.
Future<void> main() async {
  final key = _key();
  if (key.isEmpty) {
    stderr.writeln('SKIP: no API key');
    exit(2);
  }

  final api = CursorApi(apiKey: key);
  final models = await api.listModels();
  var modelId = models.first.id;
  for (final m in models) {
    if (m.id == 'composer-2.5' || m.id == 'composer-2') {
      modelId = m.id;
      break;
    }
  }
  stdout.writeln('model=$modelId');

  final created = await api.createAgent(
    text: '用两三句话说明：证明 f 可微时，为什么要把误差除以 r。不要代码。',
    modelId: modelId,
    modelParams: const [
      {'id': 'fast', 'value': 'true'},
    ],
    name: '可微与r',
    agentId: 'bc-${const Uuid().v4()}',
  );
  stdout.writeln(
    'created agent=${_short(created.agentId)} run=${_short(created.runId)}',
  );

  final first = await _readRun(api, created.agentId, created.runId);
  stdout.writeln('turn1 status=${first.status} len=${first.text.length}');
  stdout.writeln('turn1 preview=${_preview(first.text)}');
  if (first.failed || first.text.contains('运行结束')) {
    stderr.writeln('FAIL: first turn already failed');
    exit(1);
  }

  final followId = await api.createRun(
    agentId: created.agentId,
    text: '我没太明白，这个证明可微，到底怎么个流程？是不是就是按公式来？',
  );
  stdout.writeln('follow-up run=${_short(followId)}');
  final second = await _readRun(api, created.agentId, followId);
  stdout.writeln('turn2 status=${second.status} len=${second.text.length}');
  stdout.writeln('turn2 preview=${_preview(second.text)}');
  if (second.failed) {
    stdout.writeln('follow-up ERROR reproduced (this is the phone bug)');
  }
  if (second.text.contains('运行结束')) {
    stderr.writeln('FAIL: leaked 运行结束 into reply text');
    exit(1);
  }
}

class _RunOut {
  _RunOut(this.status, this.text, this.failed);
  final String status;
  final String text;
  final bool failed;
}

Future<_RunOut> _readRun(CursorApi api, String agentId, String runId) async {
  try {
    final text = await api.streamRun(
      agentId: agentId,
      runId: runId,
      onDelta: (_) {},
    );
    return _RunOut('FINISHED', text, false);
  } on RunFailedException catch (e) {
    stdout.writeln(
      'run failed: status=${e.status} code=${e.code} msg=${e.message}',
    );
    try {
      final run = await api.getRun(agentId, runId);
      stdout.writeln(
        'getRun keys=${run.keys.toList()} status=${run['status']}',
      );
    } catch (_) {}
    return _RunOut(e.status, e.userMessage, true);
  }
}

String _key() {
  final env = Platform.environment['CURSOR_API_KEY']?.trim() ?? '';
  if (env.isNotEmpty) return env;
  final file = File(
    '${Platform.environment['HOME']}/.local/share/dev.vox.cursor_chat/shared_preferences.json',
  );
  if (!file.existsSync()) return '';
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return (json['flutter.apiKey'] as String? ?? '').trim();
}

String _short(String id) {
  if (id.length <= 12) return id;
  return '${id.substring(0, 12)}…';
}

String _preview(String text) {
  final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.length <= 180) return t;
  return '${t.substring(0, 180)}…';
}
