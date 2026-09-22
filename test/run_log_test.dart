import 'dart:io';

import 'package:cursor_chat/run_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('export writes agent, run, and model into a text file', () async {
    final dir = await Directory.systemTemp.createTemp('cursor-chat-log');
    final log = RunLog(directory: dir);
    log.add(
      RunLogEntry(
        time: DateTime.utc(2026, 9, 22, 1, 2, 3),
        event: 'create-run',
        topicCode: 'Q1',
        agentId: 'bc-1',
        runId: 'run-9',
        modelId: 'claude',
        modelParams: 'fast=true',
        detail: 'hello',
      ),
    );
    final path = await log.exportText();
    expect(path, endsWith('cursor-chat-run-log.txt'));
    final text = File(path).readAsStringSync();
    expect(text, contains('bc-1'));
    expect(text, contains('run-9'));
    expect(text, contains('claude'));
    expect(text, contains('fast=true'));
    expect(text, contains('Q1'));
  });
}
