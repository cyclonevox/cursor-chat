import 'dart:async';

import 'package:cursor_chat/api/cursor_api.dart';
import 'package:cursor_chat/models/models.dart';

class FakeCursorApi extends CursorApi {
  FakeCursorApi() : super(apiKey: 'fake');

  final Map<String, Completer<String>> streams = {};
  final Map<String, String> _results = {};
  final List<String> createdPrompts = [];
  Object? nextCreateError;
  Object? nextStreamError;
  Object? nextWaitError;

  /// When true, every createRun fails with a network error (createAgent still works).
  bool failRuns = false;
  int seq = 0;

  Completer<String> _openStream(String runId) {
    final existing = streams[runId];
    if (existing != null && !existing.isCompleted) return existing;
    final c = Completer<String>();
    streams[runId] = c;
    final ready = _results[runId];
    if (ready != null) c.complete(ready);
    return c;
  }

  void _throwCreateIfNeeded() {
    if (nextCreateError != null) {
      final e = nextCreateError!;
      nextCreateError = null;
      throw e;
    }
  }

  @override
  Future<List<CursorModel>> listModels() async => const [];

  @override
  Future<CreatedAgent> createAgent({
    required String text,
    List<PromptImage> images = const [],
    String? modelId,
    List<Map<String, String>> modelParams = const [],
    String? name,
    String? agentId,
  }) async {
    _throwCreateIfNeeded();
    seq++;
    createdPrompts.add(text);
    return CreatedAgent(
      agentId: agentId ?? 'bc-$seq',
      runId: 'run-$seq',
      name: name,
    );
  }

  @override
  Future<String> createRun({
    required String agentId,
    required String text,
    List<PromptImage> images = const [],
  }) async {
    if (failRuns) {
      throw CursorApiException(0, 'Connection reset');
    }
    _throwCreateIfNeeded();
    seq++;
    createdPrompts.add(text);
    return 'run-$seq';
  }

  @override
  Future<CreatedAgent?> recoverCreated(String agentId) async => null;

  @override
  Future<AgentInfo> getAgent(String agentId) async => AgentInfo(id: agentId);

  @override
  Future<Map<String, dynamic>> getRun(String agentId, String runId) async => {
    'status': 'RUNNING',
  };

  @override
  Future<String> waitForRunText(String agentId, String runId) async {
    if (nextWaitError != null) {
      final e = nextWaitError!;
      nextWaitError = null;
      throw e;
    }
    return _openStream(runId).future;
  }

  @override
  Future<String> streamRun({
    required String agentId,
    required String runId,
    required void Function(String delta) onDelta,
    void Function(String status)? onStatus,
    void Function(String delta)? onThinking,
  }) async {
    if (nextStreamError != null) {
      final e = nextStreamError!;
      nextStreamError = null;
      throw e;
    }
    final c = _openStream(runId);
    final text = await c.future;
    if (text.isNotEmpty) onDelta(text);
    return text;
  }

  void finish(String runId, String text) {
    _results[runId] = text;
    final c = streams[runId];
    if (c != null && !c.isCompleted) {
      c.complete(text);
    } else {
      streams[runId] = Completer<String>()..complete(text);
    }
  }

  void fail(String runId, [Object? error]) {
    final c = _openStream(runId);
    if (!c.isCompleted) {
      c.completeError(error ?? RunFailedException('ERROR'));
    }
  }

  void finishAll([String text = '占位答复。']) {
    for (final c in streams.values) {
      if (!c.isCompleted) c.complete(text);
    }
  }
}
