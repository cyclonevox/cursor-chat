import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const kRunLogJsonName = 'cursor-chat-run-log.json';
const kRunLogExportName = 'cursor-chat-run-log.txt';
const kRunLogLimit = 400;

String clipLog(String? text, [int max = 2000]) {
  if (text == null) return '';
  final t = text.trim();
  if (t.length <= max) return t;
  return '${t.substring(0, max)}…';
}

class RunLogEntry {
  RunLogEntry({
    required this.time,
    required this.event,
    this.conversationId,
    this.topicCode,
    this.agentId,
    this.runId,
    this.modelId,
    this.modelParams,
    this.detail,
  });

  final DateTime time;
  final String event;
  final String? conversationId;
  final String? topicCode;
  final String? agentId;
  final String? runId;
  final String? modelId;
  final String? modelParams;
  final String? detail;

  bool get isError {
    final e = event.toLowerCase();
    return e.contains('error') ||
        e.contains('fail') ||
        e.contains('busy') ||
        e == 'sse-error';
  }

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'event': event,
    'conversationId': conversationId,
    'topicCode': topicCode,
    'agentId': agentId,
    'runId': runId,
    'modelId': modelId,
    'modelParams': modelParams,
    'detail': detail,
  };

  factory RunLogEntry.fromJson(Map<String, dynamic> json) => RunLogEntry(
    time: DateTime.tryParse('${json['time'] ?? ''}') ?? DateTime.now(),
    event: '${json['event'] ?? ''}',
    conversationId: json['conversationId'] as String?,
    topicCode: json['topicCode'] as String?,
    agentId: json['agentId'] as String?,
    runId: json['runId'] as String?,
    modelId: json['modelId'] as String?,
    modelParams: json['modelParams'] as String?,
    detail: json['detail'] as String?,
  );

  String formatLine() {
    final b = StringBuffer()..writeln('${time.toIso8601String()}  $event');
    void line(String label, String? value) {
      if (value == null || value.isEmpty) return;
      b.writeln('  $label: $value');
    }

    line('topic', topicCode ?? conversationId);
    line('agent', agentId);
    line('run', runId);
    final model = [
      if (modelId != null && modelId!.isNotEmpty) modelId,
      if (modelParams != null && modelParams!.isNotEmpty) modelParams,
    ].join(' ');
    line('model', model.isEmpty ? null : model);
    line('detail', detail);
    return b.toString().trimRight();
  }
}

class RunLog extends ChangeNotifier {
  RunLog({this.directory});

  /// When set, tests and exports stay in this folder instead of app documents.
  final Directory? directory;
  final List<RunLogEntry> entries = [];
  Future<void> _chain = Future.value();

  Future<Directory> _dir() async {
    final given = directory;
    if (given != null) return given;
    return getApplicationDocumentsDirectory();
  }

  Future<File> jsonFile() async =>
      File('${(await _dir()).path}/$kRunLogJsonName');

  Future<File> exportFile() async =>
      File('${(await _dir()).path}/$kRunLogExportName');

  Future<void> load() async {
    try {
      final file = await jsonFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      entries
        ..clear()
        ..addAll([
          for (final item in decoded)
            if (item is Map)
              RunLogEntry.fromJson(Map<String, dynamic>.from(item)),
        ]);
      _trim();
      notifyListeners();
    } catch (_) {}
  }

  void add(RunLogEntry entry) {
    entries.add(entry);
    _trim();
    notifyListeners();
    _chain = _chain.then((_) => _write()).catchError((_) {});
  }

  void clear() {
    entries.clear();
    notifyListeners();
    _chain = _chain.then((_) => _write()).catchError((_) {});
  }

  void _trim() {
    if (entries.length <= kRunLogLimit) return;
    entries.removeRange(0, entries.length - kRunLogLimit);
  }

  Future<void> _write() async {
    final file = await jsonFile();
    await file.writeAsString(jsonEncode([for (final e in entries) e.toJson()]));
  }

  /// Plain-text snapshot for debugging. Returns the file path.
  Future<String> exportText() async {
    final file = await exportFile();
    final text = [
      for (final e in entries.reversed) e.formatLine(),
    ].join('\n\n');
    await file.writeAsString(text.isEmpty ? '（还没有运行记录）\n' : '$text\n');
    return file.path;
  }
}
