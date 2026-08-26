import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api/cursor_api.dart';
import 'models/models.dart';
import 'title.dart';

class ChatStore extends ChangeNotifier {
  String apiKey = '';
  String modelId = '';
  Map<String, String> modelParams = {};
  List<CursorModel> models = [];
  final List<Conversation> conversations = [];
  String? activeId;
  bool sending = false;
  String? error;
  bool loadingModels = false;

  CursorModel? get selectedModel {
    for (final m in models) {
      if (m.id == modelId) return m;
    }
    return models.isEmpty ? null : models.first;
  }

  String get modelSummary {
    final m = selectedModel;
    if (m == null) return '选择模型';
    final bits = <String>[m.displayName];
    for (final p in m.parameters) {
      final v = modelParams[p.id];
      if (v == null) continue;
      ModelParamChoice? choice;
      for (final c in p.values) {
        if (c.value == v) choice = c;
      }
      bits.add(choice?.label ?? v);
    }
    return bits.join(' · ');
  }

  Conversation? get active {
    for (final c in conversations) {
      if (c.id == activeId) return c;
    }
    return conversations.isEmpty ? null : conversations.first;
  }

  List<Map<String, String>> get _paramsForApi {
    final m = selectedModel;
    if (m == null) return const [];
    return [
      for (final p in m.parameters)
        if (modelParams[p.id] != null)
          {'id': p.id, 'value': modelParams[p.id]!},
    ];
  }

  CursorApi? get _api {
    final key = apiKey.trim();
    if (key.isEmpty) return null;
    return CursorApi(apiKey: key);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    apiKey = prefs.getString('apiKey') ?? '';
    modelId = prefs.getString('modelId') ?? '';
    final rawParams = prefs.getString('modelParams');
    if (rawParams != null && rawParams.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawParams) as Map<String, dynamic>;
        modelParams = {for (final e in decoded.entries) e.key: '${e.value}'};
      } catch (_) {}
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/conversations.json');
      if (await file.exists()) {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        conversations
          ..clear()
          ..addAll([
            for (final c in data['items'] as List? ?? const [])
              Conversation.fromJson(c as Map<String, dynamic>),
          ]);
        activeId = data['activeId'] as String?;
      }
    } catch (_) {}
    if (conversations.isEmpty) newChat();
    notifyListeners();
    unawaited(refreshModels());
    unawaited(resumeInFlight());
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiKey', apiKey.trim());
    await prefs.setString('modelId', modelId);
    await prefs.setString('modelParams', jsonEncode(modelParams));
    notifyListeners();
  }

  Future<void> refreshModels() async {
    final api = _api;
    if (api == null) return;
    loadingModels = true;
    notifyListeners();
    try {
      models = await api.listModels();
      if (modelId.isEmpty || !models.any((m) => m.id == modelId)) {
        CursorModel pick = models.first;
        for (final m in models) {
          if (m.id == 'composer-2.5' || m.id == 'composer-2') {
            pick = m;
            break;
          }
        }
        selectModel(pick.id, persist: false);
      } else {
        _sanitizeParams(selectedModel);
      }
      error = null;
    } on CursorApiException catch (e) {
      error = '无法拉取模型列表：${e.status}';
    } catch (e) {
      error = e.toString();
    } finally {
      loadingModels = false;
      notifyListeners();
    }
  }

  void selectModel(String id, {bool persist = true}) {
    modelId = id;
    final m = selectedModel;
    modelParams = m?.alignedParams({}) ?? {};
    notifyListeners();
    if (persist) unawaited(saveSettings());
  }

  void setParam(String id, String value) {
    modelParams[id] = value;
    notifyListeners();
    unawaited(saveSettings());
  }

  void _sanitizeParams(CursorModel? m) {
    if (m == null) return;
    modelParams = m.alignedParams(modelParams);
  }

  void newChat() {
    final c = Conversation(id: uuid.v4(), title: '新对话');
    conversations.insert(0, c);
    activeId = c.id;
    error = null;
    notifyListeners();
    unawaited(_persist());
  }

  void selectChat(String id) {
    activeId = id;
    notifyListeners();
    unawaited(_persist());
  }

  void deleteChat(String id) {
    conversations.removeWhere((c) => c.id == id);
    if (activeId == id) {
      activeId = conversations.isEmpty ? null : conversations.first.id;
    }
    if (conversations.isEmpty) newChat();
    notifyListeners();
    unawaited(_persist());
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  /// After the app is backgrounded or killed, pick up a run that already exists.
  Future<void> resumeInFlight() async {
    if (sending) return;
    Conversation? conv;
    ChatMessage? assistant;
    for (final c in conversations) {
      for (final m in c.messages.reversed) {
        if (m.role == 'assistant' && m.streaming) {
          conv = c;
          assistant = m;
          break;
        }
      }
      if (assistant != null) break;
    }
    if (conv == null || assistant == null) return;
    final api = _api;
    if (api == null) return;

    sending = true;
    error = null;
    notifyListeners();
    final conv0 = conv;
    final assistant0 = assistant;
    await _withWakeLock(() async {
      try {
        final ids = await _ensureRun(api, conv0);
        await _collectRun(api, conv0, assistant0, ids.$1, ids.$2);
      } catch (e) {
        error = friendlyNetworkError(e);
        if (assistant0.text.isEmpty) {
          assistant0.text = '出错了：$error';
        }
        assistant0.streaming = false;
        conv0.pendingRunId = null;
      } finally {
        sending = false;
        conv0.updatedAt = DateTime.now();
        notifyListeners();
        await _persist();
      }
    });
  }

  Future<void> send({
    required String text,
    List<PromptImage> images = const [],
  }) async {
    final api = _api;
    if (api == null) {
      error = '先在设置里填入 Cursor API Key';
      notifyListeners();
      return;
    }
    var conv = active;
    if (conv == null) {
      newChat();
      conv = active!;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty && images.isEmpty) return;
    if (sending) return;

    final displayText = trimmed.isEmpty ? '（图片）' : trimmed;
    conv.messages.add(
      ChatMessage(
        id: uuid.v4(),
        role: 'user',
        text: displayText,
        imagePaths: [
          for (final img in images)
            if (img.path != null) img.path!,
        ],
      ),
    );
    conv.title = conversationTitle(displayText);
    conv.updatedAt = DateTime.now();

    final assistant = ChatMessage(
      id: uuid.v4(),
      role: 'assistant',
      text: '',
      streaming: true,
    );
    conv.messages.add(assistant);
    sending = true;
    error = null;
    notifyListeners();
    await _persist();

    final question = trimmed.isEmpty ? '请看图，解释内容并回答该怎么做、为什么。' : trimmed;
    final userTurns = conv.messages.where((m) => m.role == 'user').length;
    final apiText = userTurns <= 1
        ? '$kFirstTurnPrefix${recencyPreamble()}$question'
        : '${recencyPreamble()}$question';
    final conversation = conv;

    await _withWakeLock(() async {
      try {
        if (conversation.agentId == null) {
          conversation.agentId = 'bc-${uuid.v4()}';
          await _persist();
        }
        final created = userTurns <= 1
            ? await _createFirstRun(api, conversation, apiText, images)
            : await _createFollowUp(api, conversation, apiText, images);
        conversation.agentId = created.agentId;
        conversation.pendingRunId = created.runId;
        await _persist();
        await _collectRun(
          api,
          conversation,
          assistant,
          created.agentId,
          created.runId,
        );
      } catch (e) {
        error = friendlyNetworkError(e);
        if (assistant.text.isEmpty) assistant.text = '出错了：$error';
        assistant.streaming = false;
        conversation.pendingRunId = null;
      } finally {
        sending = false;
        conversation.updatedAt = DateTime.now();
        conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        notifyListeners();
        await _persist();
      }
    });
  }

  Future<CreatedAgent> _createFirstRun(
    CursorApi api,
    Conversation conv,
    String apiText,
    List<PromptImage> images,
  ) async {
    try {
      return await api.createAgent(
        text: apiText,
        images: images,
        modelId: modelId.isEmpty ? null : modelId,
        modelParams: _paramsForApi,
        name: conv.title == '新对话' ? null : conv.title,
        agentId: conv.agentId,
      );
    } catch (e) {
      if (conv.agentId != null &&
          (isTransientNetworkError(e) ||
              (e is CursorApiException && e.status == 409))) {
        final recovered = await api.recoverCreated(conv.agentId!);
        if (recovered != null) return recovered;
      }
      rethrow;
    }
  }

  Future<CreatedAgent> _createFollowUp(
    CursorApi api,
    Conversation conv,
    String apiText,
    List<PromptImage> images,
  ) async {
    final agentId = conv.agentId!;
    try {
      final runId = await api.createRun(
        agentId: agentId,
        text: apiText,
        images: images,
      );
      return CreatedAgent(agentId: agentId, runId: runId);
    } catch (e) {
      if (isTransientNetworkError(e)) {
        try {
          final agent = await api.getAgent(agentId);
          final runId = agent.latestRunId;
          if (runId != null && runId.isNotEmpty) {
            final run = await api.getRun(agentId, runId);
            final created = DateTime.tryParse('${run['createdAt'] ?? ''}');
            final assistantAt = conv.messages.last.createdAt;
            if (created == null ||
                !created.isBefore(
                  assistantAt.subtract(const Duration(seconds: 3)),
                )) {
              return CreatedAgent(agentId: agentId, runId: runId);
            }
          }
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<(String, String)> _ensureRun(CursorApi api, Conversation conv) async {
    if (conv.agentId != null &&
        conv.pendingRunId != null &&
        conv.pendingRunId!.isNotEmpty) {
      return (conv.agentId!, conv.pendingRunId!);
    }
    if (conv.agentId != null) {
      final recovered = await api.recoverCreated(conv.agentId!);
      if (recovered != null) {
        conv.pendingRunId = recovered.runId;
        await _persist();
        return (recovered.agentId, recovered.runId);
      }
    }
    throw CursorApiException(0, '上次请求还没发出去，请再发一次。');
  }

  Future<void> _collectRun(
    CursorApi api,
    Conversation conv,
    ChatMessage assistant,
    String agentId,
    String runId,
  ) async {
    conv.agentId = agentId;
    conv.pendingRunId = runId;
    await _persist();

    var finalText = '';
    try {
      finalText = await api.streamRun(
        agentId: agentId,
        runId: runId,
        onDelta: (delta) {
          assistant.text += delta;
          notifyListeners();
        },
        onThinking: (delta) {
          assistant.thinking += delta;
          notifyListeners();
        },
      );
    } catch (e) {
      if (!isTransientNetworkError(e) &&
          !(e is CursorApiException && e.status == 0)) {
        rethrow;
      }
      try {
        finalText = await api.waitForRunText(agentId, runId);
      } catch (pollError) {
        if (assistant.text.trim().isNotEmpty) {
          error = null;
          assistant.streaming = false;
          conv.pendingRunId = null;
          return;
        }
        rethrow;
      }
    }

    if (finalText.isNotEmpty &&
        (assistant.text.isEmpty || finalText.length >= assistant.text.length)) {
      assistant.text = finalText;
    }
    if (assistant.text.trim().isEmpty) {
      assistant.text = '（没有文字回复）';
    }
    assistant.streaming = false;
    conv.pendingRunId = null;
    error = null;
  }

  Future<void> _withWakeLock(Future<void> Function() fn) async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    try {
      await fn();
    } finally {
      try {
        await WakelockPlus.disable();
      } catch (_) {}
    }
  }

  Future<void> _persist() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/conversations.json');
      await file.writeAsString(
        jsonEncode({
          'activeId': activeId,
          'items': [for (final c in conversations) c.toJson()],
        }),
      );
    } catch (_) {}
  }
}
