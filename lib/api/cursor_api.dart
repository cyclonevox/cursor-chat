import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'sse.dart';

const kCursorApiKeyUrl = 'https://cursor.com/dashboard/api';

class CancelToken {
  bool _cancelled = false;
  HttpClient? _client;
  void Function()? onCancel;

  bool get isCancelled => _cancelled;

  void attach(HttpClient client) {
    _client = client;
    if (_cancelled) client.close(force: true);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _client?.close(force: true);
    onCancel?.call();
  }
}

class CreatedAgent {
  const CreatedAgent({required this.agentId, required this.runId, this.name});
  final String agentId;
  final String runId;
  final String? name;
}

class AgentInfo {
  const AgentInfo({required this.id, this.name, this.latestRunId, this.status});
  final String id;
  final String? name;
  final String? latestRunId;
  final String? status;
}

class AgentTokenUsage {
  const AgentTokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
  });
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  int get promptish => inputTokens + cacheReadTokens;
}

class ModelParamChoice {
  const ModelParamChoice({required this.value, this.displayName});
  final String value;
  final String? displayName;

  String get label {
    if (displayName != null && displayName!.trim().isNotEmpty) {
      return displayName!;
    }
    if (value == 'false') return '标准';
    if (value == 'true') return 'Fast';
    return value;
  }
}

class ModelParameter {
  const ModelParameter({
    required this.id,
    this.displayName,
    this.values = const [],
  });
  final String id;
  final String? displayName;
  final List<ModelParamChoice> values;

  String get label =>
      displayName?.trim().isNotEmpty == true ? displayName! : id;
}

class ModelVariant {
  const ModelVariant({
    required this.displayName,
    required this.params,
    this.isDefault = false,
  });
  final String displayName;
  final Map<String, String> params;
  final bool isDefault;
}

class CursorModel {
  const CursorModel({
    required this.id,
    required this.displayName,
    this.parameters = const [],
    this.variants = const [],
    this.defaultParams = const {},
  });
  final String id;
  final String displayName;
  final List<ModelParameter> parameters;
  final List<ModelVariant> variants;
  final Map<String, String> defaultParams;

  factory CursorModel.fromJson(Map<String, dynamic> json) {
    final parameters = <ModelParameter>[
      for (final raw in json['parameters'] as List? ?? const [])
        ModelParameter(
          id: (raw as Map)['id'] as String,
          displayName: raw['displayName'] as String?,
          values: [
            for (final v in raw['values'] as List? ?? const [])
              ModelParamChoice(
                value: '${(v as Map)['value']}',
                displayName: v['displayName'] as String?,
              ),
          ],
        ),
    ];
    final variants = <ModelVariant>[
      for (final raw in json['variants'] as List? ?? const [])
        ModelVariant(
          displayName:
              (raw as Map)['displayName'] as String? ??
              json['displayName'] as String? ??
              json['id'] as String,
          isDefault: raw['isDefault'] == true,
          params: {
            for (final p in raw['params'] as List? ?? const [])
              '${(p as Map)['id']}': '${p['value']}',
          },
        ),
    ];
    final defaultParams = <String, String>{};
    for (final v in variants) {
      if (v.isDefault) {
        defaultParams.addAll(v.params);
        break;
      }
    }
    return CursorModel(
      id: json['id'] as String,
      displayName: json['displayName'] as String? ?? json['id'] as String,
      parameters: parameters,
      variants: variants,
      defaultParams: defaultParams,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'parameters': [
      for (final p in parameters)
        {
          'id': p.id,
          'displayName': p.displayName,
          'values': [
            for (final v in p.values)
              {'value': v.value, 'displayName': v.displayName},
          ],
        },
    ],
    'variants': [
      for (final v in variants)
        {
          'displayName': v.displayName,
          'isDefault': v.isDefault,
          'params': [
            for (final e in v.params.entries) {'id': e.key, 'value': e.value},
          ],
        },
    ],
  };

  /// Only ids this model advertises; drops leftover params from the previous model.
  Map<String, String> alignedParams(Map<String, String> current) {
    final out = <String, String>{};
    for (final p in parameters) {
      if (p.values.isEmpty) continue;
      final cur = current[p.id];
      if (cur != null && p.values.any((v) => v.value == cur)) {
        out[p.id] = cur;
      } else if (defaultParams[p.id] != null) {
        out[p.id] = defaultParams[p.id]!;
      } else {
        out[p.id] = p.values.first.value;
      }
    }
    return out;
  }

  String catalogLine() {
    if (parameters.isEmpty) return '$id  ($displayName)  无额外参数';
    final parts = [
      for (final p in parameters)
        '${p.label}[${p.values.map((v) => v.label).join("/")}]',
    ];
    return '$id  ($displayName)  ${parts.join("  ")}';
  }
}

class CursorApi {
  CursorApi({
    required this.apiKey,
    this.baseUrl = 'https://api.cursor.com',
    this.onLog,
  });

  final String apiKey;
  final String baseUrl;
  void Function(String event, Map<String, Object?> fields)? onLog;

  void _log(String event, [Map<String, Object?> fields = const {}]) {
    final sink = onLog;
    if (sink == null) return;
    try {
      sink(event, fields);
    } catch (_) {}
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  HttpClient _client() {
    final client = HttpClient();
    client.idleTimeout = const Duration(minutes: 10);
    client.connectionTimeout = const Duration(seconds: 30);
    return client;
  }

  Future<List<CursorModel>> listModels() async {
    final json = await _json('GET', '/v1/models');
    final items = json['items'] as List? ?? const [];
    return [
      for (final item in items)
        CursorModel.fromJson(Map<String, dynamic>.from(item as Map)),
    ];
  }

  Future<CreatedAgent> createAgent({
    required String text,
    List<PromptImage> images = const [],
    String? modelId,
    List<Map<String, String>> modelParams = const [],
    String? name,
    String? agentId,
  }) async {
    final body = <String, dynamic>{
      'prompt': _prompt(text, images),
      if (modelId != null && modelId.isNotEmpty)
        'model': {
          'id': modelId,
          if (modelParams.isNotEmpty) 'params': modelParams,
        },
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (agentId != null && agentId.isNotEmpty) 'agentId': agentId,
    };
    try {
      final json = await _json('POST', '/v1/agents', body: body);
      return _createdFrom(json);
    } on CursorApiException catch (e) {
      if (e.status == 409 && agentId != null && agentId.isNotEmpty) {
        final recovered = await recoverCreated(agentId);
        if (recovered != null) return recovered;
      }
      rethrow;
    }
  }

  CreatedAgent _createdFrom(Map<String, dynamic> json) {
    final agent = json['agent'] as Map<String, dynamic>? ?? json;
    final run = json['run'] as Map<String, dynamic>?;
    final agentId = agent['id'] as String;
    final runId =
        run?['id'] as String? ?? agent['latestRunId'] as String? ?? '';
    if (runId.isEmpty) {
      throw CursorApiException(0, '创建成功但没有 run id');
    }
    return CreatedAgent(
      agentId: agentId,
      runId: runId,
      name: agent['name'] as String?,
    );
  }

  Future<CreatedAgent?> recoverCreated(String agentId) async {
    try {
      final agent = await getAgent(agentId);
      final runId = agent.latestRunId;
      if (runId == null || runId.isEmpty) return null;
      return CreatedAgent(agentId: agent.id, runId: runId, name: agent.name);
    } on CursorApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<AgentInfo> getAgent(String agentId) async {
    final json = await _json('GET', '/v1/agents/$agentId');
    return _agentInfo(json);
  }

  Future<AgentTokenUsage> getAgentUsage(String agentId, {String? runId}) async {
    var path = '/v1/agents/$agentId/usage';
    if (runId != null && runId.isNotEmpty) {
      path = '$path?runId=$runId';
    }
    final json = await _json('GET', path);
    return _agentTokenUsageFrom(json, runId: runId);
  }

  Future<List<AgentInfo>> listAgents({int limit = 100}) async {
    final json = await _json(
      'GET',
      '/v1/agents?limit=$limit&includeArchived=false',
    );
    final items = json['items'] as List? ?? json['agents'] as List? ?? const [];
    return [
      for (final item in items)
        _agentInfo(Map<String, dynamic>.from(item as Map)),
    ];
  }

  Future<void> deleteAgent(String agentId) async {
    await _json('DELETE', '/v1/agents/$agentId');
  }

  AgentInfo _agentInfo(Map<String, dynamic> json) => AgentInfo(
    id: json['id'] as String,
    name: json['name'] as String?,
    latestRunId: json['latestRunId'] as String?,
    status: json['status'] as String?,
  );

  AgentTokenUsage _agentTokenUsageFrom(
    Map<String, dynamic> json, {
    String? runId,
  }) {
    final runs = json['runs'] is List ? json['runs'] as List : const [];
    Map<String, dynamic>? picked;
    if (runId != null && runId.isNotEmpty) {
      for (final item in runs) {
        if (item is Map && item['id'] == runId) {
          picked = _usageMap(item['usage']);
          break;
        }
      }
    }
    if (picked == null && runs.isNotEmpty) {
      final first = runs.first;
      picked = first is Map ? _usageMap(first['usage']) : null;
    }
    picked ??= _usageMap(json['totalUsage']);
    return AgentTokenUsage(
      inputTokens: _tokenCount(picked?['inputTokens']),
      outputTokens: _tokenCount(picked?['outputTokens']),
      cacheReadTokens: _tokenCount(picked?['cacheReadTokens']),
      cacheWriteTokens: _tokenCount(picked?['cacheWriteTokens']),
    );
  }

  Map<String, dynamic>? _usageMap(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  int _tokenCount(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  Future<String> createRun({
    required String agentId,
    required String text,
    List<PromptImage> images = const [],
  }) async {
    CursorApiException? last;
    for (var i = 0; i < 4; i++) {
      try {
        final json = await _json(
          'POST',
          '/v1/agents/$agentId/runs',
          body: {'prompt': _prompt(text, images)},
        );
        final run = json['run'] as Map<String, dynamic>? ?? json;
        final id = run['id'] as String;
        _log('create-run', {'agentId': agentId, 'runId': id});
        return id;
      } on CursorApiException catch (e) {
        last = e;
        _log('create-run-error', {
          'agentId': agentId,
          'status': e.status,
          'body': e.body.length > 500 ? e.body.substring(0, 500) : e.body,
        });
        if (e.status == 404) {
          await Future<void>.delayed(Duration(milliseconds: 200 * (i + 1)));
          continue;
        }
        rethrow;
      }
    }
    throw last ?? CursorApiException(404, 'agent_not_ready');
  }

  Future<Map<String, dynamic>> getRun(String agentId, String runId) async {
    final json = await _json('GET', '/v1/agents/$agentId/runs/$runId');
    return Map<String, dynamic>.from(json['run'] as Map? ?? json);
  }

  Future<void> cancelRun(String agentId, String runId) async {
    await _json('POST', '/v1/agents/$agentId/runs/$runId/cancel');
  }

  /// Streams assistant text deltas. Completes with the final text.
  /// A stream `error` event is not a finished run: reconnect, then poll Get Run.
  /// Text seen before a `result` event is not treated as the final reply.
  Future<String> streamRun({
    required String agentId,
    required String runId,
    required void Function(String delta) onDelta,
    void Function(String status)? onStatus,
    void Function(String delta)? onThinking,
    CancelToken? cancelToken,
  }) async {
    final assembled = StringBuffer();
    String? lastEventId;
    var resumeReason = 'closed';
    for (var attempt = 0; attempt < 3; attempt++) {
      if (cancelToken?.isCancelled == true) {
        throw RunFailedException('CANCELLED');
      }
      if (attempt > 0 && (lastEventId == null || lastEventId.isEmpty)) {
        break;
      }
      final read = await _readStream(
        agentId: agentId,
        runId: runId,
        lastEventId: attempt == 0 ? null : lastEventId,
        assembled: assembled,
        onDelta: onDelta,
        onStatus: onStatus,
        onThinking: onThinking,
        cancelToken: cancelToken,
      );
      if (read.lastEventId != null && read.lastEventId!.isNotEmpty) {
        lastEventId = read.lastEventId;
      }
      if (read.terminal) {
        return read.text ?? assembled.toString();
      }
      resumeReason = read.resume ?? 'closed';
      _log('stream-resume', {
        'agentId': agentId,
        'runId': runId,
        'attempt': attempt,
        'reason': resumeReason,
      });
    }
    if (cancelToken?.isCancelled == true) {
      throw RunFailedException('CANCELLED');
    }
    try {
      final polled = await waitForRunText(agentId, runId);
      if (polled.trim().isEmpty) {
        return assembled.isNotEmpty ? assembled.toString() : polled;
      }
      if (assembled.isEmpty || polled.length >= assembled.length) {
        return polled;
      }
      return assembled.toString();
    } catch (e) {
      if (e is RunFailedException) rethrow;
      if (assembled.isNotEmpty && resumeReason == 'closed') {
        final run = await getRun(agentId, runId);
        final st = run['status'] as String? ?? '';
        if (!isLiveRunStatus(st)) return assembled.toString();
      }
      rethrow;
    }
  }

  Future<_StreamRead> _readStream({
    required String agentId,
    required String runId,
    required String? lastEventId,
    required StringBuffer assembled,
    required void Function(String delta) onDelta,
    void Function(String status)? onStatus,
    void Function(String delta)? onThinking,
    CancelToken? cancelToken,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/agents/$agentId/runs/$runId/stream');
    final client = _client();
    cancelToken?.attach(client);
    if (cancelToken?.isCancelled == true) {
      client.close(force: true);
      throw RunFailedException('CANCELLED');
    }
    String? newestId = lastEventId;
    var deltas = 0;
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (lastEventId != null && lastEventId.isNotEmpty) {
        req.headers.set('Last-Event-ID', lastEventId);
      }
      final res = await req.close();
      if (res.statusCode == 410) {
        return _StreamRead.resume('http-410', newestId);
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final body = await utf8.decodeStream(res);
        final err = CursorApiException(res.statusCode, body);
        if (err.isStreamGone) {
          return _StreamRead.resume('stream-gone', newestId);
        }
        throw err;
      }
      final parser = SseParser();
      await for (final chunk in res.transform(utf8.decoder)) {
        for (final event in parser.add(chunk)) {
          if (event.id != null && event.id!.isNotEmpty) newestId = event.id;
          Map<String, dynamic> data = const {};
          if (event.data.isNotEmpty) {
            try {
              data = jsonDecode(event.data) as Map<String, dynamic>;
            } catch (_) {}
          }
          switch (event.event) {
            case 'status':
              final st = data['status'] as String? ?? '';
              onStatus?.call(st);
              _log('run-status', {
                'agentId': agentId,
                'runId': runId,
                'status': st,
              });
              if (isFailedRunStatus(st)) {
                throw RunFailedException(st, message: runFailureMessage(data));
              }
            case 'thinking':
              final think = data['text'] as String? ?? '';
              if (think.isNotEmpty) onThinking?.call(think);
            case 'assistant':
              final text = data['text'] as String? ?? '';
              if (text.isNotEmpty) {
                assembled.write(text);
                deltas++;
                onDelta(text);
              }
            case 'result':
              final st = data['status'] as String? ?? '';
              _log('run-result', {
                'agentId': agentId,
                'runId': runId,
                'status': st,
                'deltas': deltas,
              });
              if (isFailedRunStatus(st)) {
                throw RunFailedException(st, message: runFailureMessage(data));
              }
              final text = data['text'] as String?;
              if (text != null &&
                  text.isNotEmpty &&
                  isFailedAssistantText(text)) {
                throw RunFailedException('ERROR', message: text);
              }
              if (text != null && text.isNotEmpty) {
                return _StreamRead.terminal(text, newestId);
              }
              return _StreamRead.terminal(assembled.toString(), newestId);
            case 'error':
              final code = data['code'] as String? ?? '';
              final message = data['message'] as String? ?? event.data;
              _log('sse-error', {
                'agentId': agentId,
                'runId': runId,
                'code': code,
                'message': message.length > 500
                    ? message.substring(0, 500)
                    : message,
              });
              return _StreamRead.resume(
                code.isEmpty ? 'sse-error' : 'sse-error:$code',
                newestId,
              );
            case 'done':
              return _StreamRead.resume('done', newestId);
            default:
              break;
          }
        }
      }
      _log('stream-closed', {
        'agentId': agentId,
        'runId': runId,
        'deltas': deltas,
      });
      return _StreamRead.resume('closed', newestId);
    } on RunFailedException {
      rethrow;
    } on CursorApiException catch (e) {
      if (cancelToken?.isCancelled == true) {
        throw RunFailedException('CANCELLED');
      }
      if (e.status != 0 && !e.isStreamGone) rethrow;
      return _StreamRead.resume('network', newestId);
    } catch (e) {
      if (cancelToken?.isCancelled == true) {
        throw RunFailedException('CANCELLED');
      }
      if (!isTransientNetworkError(e)) rethrow;
      return _StreamRead.resume('network', newestId);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> waitForRunText(String agentId, String runId) async {
    CursorApiException? last;
    for (var i = 0; i < 120; i++) {
      try {
        final run = await getRun(agentId, runId);
        final status = run['status'] as String? ?? '';
        if (isFailedRunStatus(status)) {
          throw RunFailedException(status, message: runFailureMessage(run));
        }
        if (status == 'FINISHED') {
          final result = run['result'] as String? ?? '';
          if (isFailedAssistantText(result)) {
            throw RunFailedException('ERROR', message: result);
          }
          return result;
        }
      } catch (e) {
        if (e is RunFailedException) rethrow;
        if (e is CursorApiException) last = e;
        if (!isTransientNetworkError(e) &&
            e is CursorApiException &&
            e.status != 404 &&
            e.status != 409) {
          rethrow;
        }
      }
      await Future<void>.delayed(Duration(seconds: i < 8 ? 1 : 2));
    }
    throw last ?? CursorApiException(0, '等待回复超时');
  }

  Map<String, dynamic> _prompt(String text, List<PromptImage> images) => {
    'text': text,
    if (images.isNotEmpty)
      'images': [for (final img in images) img.toApiJson()],
  };

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Object? body,
  }) async {
    final client = _client();
    try {
      final uri = Uri.parse('$baseUrl$path');
      final req = await switch (method) {
        'GET' => client.getUrl(uri),
        'POST' => client.postUrl(uri),
        'DELETE' => client.deleteUrl(uri),
        _ => throw ArgumentError(method),
      };
      _headers.forEach(req.headers.set);
      if (body != null) {
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw CursorApiException(res.statusCode, text);
      }
      if (text.isEmpty) return {};
      return jsonDecode(text) as Map<String, dynamic>;
    } on CursorApiException {
      rethrow;
    } catch (e) {
      if (isTransientNetworkError(e)) {
        throw CursorApiException(0, e.toString());
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

class _StreamRead {
  _StreamRead.terminal(this.text, this.lastEventId) : resume = null;
  _StreamRead.resume(this.resume, this.lastEventId) : text = null;

  final String? text;
  final String? resume;
  final String? lastEventId;

  bool get terminal => resume == null;
}

bool isTransientNetworkError(Object e) {
  if (e is SocketException ||
      e is HttpException ||
      e is HandshakeException ||
      e is TlsException ||
      e is TimeoutException) {
    return true;
  }
  if (e is CursorApiException) {
    if (e.status == 0) return true;
    if (e.status >= 500) return true;
  }
  final s = e.toString().toLowerCase();
  return s.contains('socketexception') ||
      s.contains('connection closed') ||
      s.contains('connection reset') ||
      s.contains('broken pipe') ||
      s.contains('connection abort') ||
      s.contains('network is unreachable') ||
      s.contains('timed out') ||
      s.contains('timeout') ||
      s.contains('clientexception') ||
      s.contains('connection error');
}

String friendlyNetworkError(Object e) {
  if (e is RunFailedException) return e.userMessage;
  if (isTransientNetworkError(e)) {
    return '网络中断了。点重发会立刻再试；云端还在跑的话会把结果拉回来。';
  }
  return e.toString();
}

const kFirstTurnPrefix =
    '你是手机上的通用助手，拍题、闲聊、工作问题都直接答，像 ChatGPT 一样说话。'
    '有照片时先看清图再答；讲题把关键步骤和原因说清。'
    '用户没明确要求时，不要建仓库、开 PR、改项目，也不要主动写一堆代码。'
    '用用户的语言，短而清楚。\n\n';
