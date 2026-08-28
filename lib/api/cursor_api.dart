import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/models.dart';
import 'sse.dart';

const kCursorApiKeyUrl = 'https://cursor.com/dashboard/api';

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
  CursorApi({required this.apiKey, this.baseUrl = 'https://api.cursor.com'});

  final String apiKey;
  final String baseUrl;

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
    return AgentInfo(
      id: json['id'] as String,
      name: json['name'] as String?,
      latestRunId: json['latestRunId'] as String?,
      status: json['status'] as String?,
    );
  }

  Future<String> createRun({
    required String agentId,
    required String text,
    List<PromptImage> images = const [],
  }) async {
    CursorApiException? last;
    for (var i = 0; i < 8; i++) {
      try {
        final json = await _json(
          'POST',
          '/v1/agents/$agentId/runs',
          body: {'prompt': _prompt(text, images)},
        );
        final run = json['run'] as Map<String, dynamic>? ?? json;
        return run['id'] as String;
      } on CursorApiException catch (e) {
        last = e;
        if (e.status != 409 || e.isStreamGone) rethrow;
        await Future<void>.delayed(Duration(seconds: 1 + i));
      }
    }
    throw last ?? CursorApiException(409, 'agent_busy');
  }

  Future<Map<String, dynamic>> getRun(String agentId, String runId) async {
    final json = await _json('GET', '/v1/agents/$agentId/runs/$runId');
    return Map<String, dynamic>.from(json['run'] as Map? ?? json);
  }

  Future<void> cancelRun(String agentId, String runId) async {
    await _json('POST', '/v1/agents/$agentId/runs/$runId/cancel');
  }

  /// Streams assistant text deltas. Completes with the final text.
  /// If the socket drops (app backgrounded, radio sleep), falls back to polling.
  Future<String> streamRun({
    required String agentId,
    required String runId,
    required void Function(String delta) onDelta,
    void Function(String status)? onStatus,
    void Function(String delta)? onThinking,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/agents/$agentId/runs/$runId/stream');
    final client = _client();
    final assembled = StringBuffer();
    var poll = false;
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      final res = await req.close();
      if (res.statusCode == 410) {
        poll = true;
      } else if (res.statusCode < 200 || res.statusCode >= 300) {
        final body = await utf8.decodeStream(res);
        final err = CursorApiException(res.statusCode, body);
        if (err.isStreamGone) {
          poll = true;
        } else {
          throw err;
        }
      } else {
        final parser = SseParser();
        await for (final chunk in res.transform(utf8.decoder)) {
          for (final event in parser.add(chunk)) {
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
                if (isFailedRunStatus(st)) {
                  throw RunFailedException(
                    st,
                    message: runFailureMessage(data),
                  );
                }
              case 'thinking':
                final think = data['text'] as String? ?? '';
                if (think.isNotEmpty) onThinking?.call(think);
              case 'assistant':
                final text = data['text'] as String? ?? '';
                if (text.isNotEmpty) {
                  assembled.write(text);
                  onDelta(text);
                }
              case 'result':
                final st = data['status'] as String? ?? '';
                if (isFailedRunStatus(st)) {
                  throw RunFailedException(
                    st,
                    message: runFailureMessage(data),
                  );
                }
                final text = data['text'] as String?;
                if (text != null && text.isNotEmpty) {
                  if (isFailedAssistantText(text)) {
                    throw RunFailedException('ERROR', message: text);
                  }
                  return text;
                }
              case 'error':
                throw RunFailedException(
                  'ERROR',
                  code: data['code'] as String?,
                  message: data['message'] as String? ?? event.data,
                );
              case 'done':
                if (assembled.isNotEmpty) return assembled.toString();
                poll = true;
            }
          }
        }
        if (assembled.isNotEmpty) return assembled.toString();
        poll = true;
      }
    } on RunFailedException {
      rethrow;
    } on CursorApiException catch (e) {
      if (e.status != 0 && !e.isStreamGone) rethrow;
      poll = true;
    } catch (e) {
      if (!isTransientNetworkError(e)) rethrow;
      poll = true;
    } finally {
      client.close(force: true);
    }
    if (poll) {
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
        if (assembled.isNotEmpty) return assembled.toString();
        rethrow;
      }
    }
    return assembled.toString();
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
