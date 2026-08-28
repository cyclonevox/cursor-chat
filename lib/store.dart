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
  ChatStore({CursorApi? client}) : _client = client;

  final CursorApi? _client;
  String apiKey = '';
  String modelId = '';
  Map<String, String> modelParams = {};
  List<CursorModel> models = [];
  final List<Conversation> conversations = [];
  String? activeId;
  final Set<String> _inFlight = {};
  String? error;
  String? errorChatId;
  String? modelsError;
  bool loadingModels = false;
  int _wakeLocks = 0;
  Future<void> _persistChain = Future.value();
  Future<void>? _modelsInFlight;
  Timer? _modelsRetryTimer;

  /// Extra pauses between listModels attempts. Empty means a single try.
  @visibleForTesting
  List<Duration> modelsRetryDelays = const [
    Duration(milliseconds: 800),
    Duration(seconds: 2),
  ];

  /// After the retry loop still has no catalog, wait and try again.
  @visibleForTesting
  Duration modelsRescheduleDelay = const Duration(seconds: 12);

  @visibleForTesting
  bool rescheduleModelsOnFailure = true;

  bool isSending(String? id) => id != null && _inFlight.contains(id);

  /// True only while the *active* chat is waiting on a reply.
  bool get sending => isSending(activeId);

  /// Last bubble is a failed/empty assistant reply that can be sent again.
  bool get canRetryLast => !sending && _retryTarget(active) != null;

  String? get visibleError {
    if (error == null) return null;
    if (errorChatId == null || errorChatId == activeId) return error;
    return null;
  }

  CursorModel? get selectedModel {
    for (final m in models) {
      if (m.id == modelId) return m;
    }
    return models.isEmpty ? null : models.first;
  }

  String get modelSummary {
    final m = selectedModel;
    if (m == null) {
      if (loadingModels) return '正在加载模型…';
      if (modelId.isNotEmpty) return modelId;
      return '选择模型';
    }
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
    if (_client != null) return _client;
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
    final rawModels = prefs.getString('models');
    if (rawModels != null && rawModels.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawModels) as List;
        models = [
          for (final m in decoded)
            CursorModel.fromJson(Map<String, dynamic>.from(m as Map)),
        ];
        _sanitizeParams(selectedModel);
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
    if (models.isEmpty) unawaited(refreshModels());
    unawaited(resumeInFlight());
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiKey', apiKey.trim());
    await prefs.setString('modelId', modelId);
    await prefs.setString('modelParams', jsonEncode(modelParams));
    if (models.isNotEmpty) {
      await prefs.setString(
        'models',
        jsonEncode([for (final m in models) m.toJson()]),
      );
    }
    notifyListeners();
  }

  Future<void> refreshModels({bool force = false}) {
    if (!force && models.isNotEmpty) return Future.value();
    return _modelsInFlight ??= _refreshModelsBody().whenComplete(() {
      _modelsInFlight = null;
    });
  }

  Future<void> _refreshModelsBody() async {
    final api = _api;
    if (api == null) return;
    _modelsRetryTimer?.cancel();
    loadingModels = true;
    notifyListeners();
    Object? lastError;
    var attempt = 0;
    while (true) {
      try {
        final next = await api.listModels();
        if (next.isEmpty) {
          lastError = CursorApiException(0, 'empty catalog');
        } else {
          _applyCatalog(next);
          modelsError = null;
          loadingModels = false;
          notifyListeners();
          await saveSettings();
          return;
        }
      } catch (e) {
        lastError = e;
        if (!_shouldRetryModels(e)) break;
      }
      if (attempt >= modelsRetryDelays.length) break;
      await Future<void>.delayed(modelsRetryDelays[attempt]);
      attempt++;
    }
    modelsError = _friendlyModelsError(lastError);
    loadingModels = false;
    notifyListeners();
    if (models.isEmpty) _armModelsRetry();
  }

  void _applyCatalog(List<CursorModel> next) {
    models = next;
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
  }

  bool _shouldRetryModels(Object e) {
    if (e is CursorApiException && (e.status == 401 || e.status == 403)) {
      return false;
    }
    return true;
  }

  String _friendlyModelsError(Object? e) {
    if (e is CursorApiException && (e.status == 401 || e.status == 403)) {
      return '这个 Key 好像不对。请到网页重新创建再粘贴。';
    }
    if (e != null && isTransientNetworkError(e)) {
      return '模型列表暂时没拉到，会自动再试。有缓存的话可以继续用。';
    }
    return '模型列表暂时没拉到，会自动再试。';
  }

  void _armModelsRetry() {
    _modelsRetryTimer?.cancel();
    if (!rescheduleModelsOnFailure || models.isNotEmpty || _api == null) {
      return;
    }
    _modelsRetryTimer = Timer(modelsRescheduleDelay, () {
      unawaited(refreshModels());
    });
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
    errorChatId = null;
    notifyListeners();
  }

  /// After the app is backgrounded or killed, pick up runs that already exist.
  /// Also retries a failed last bubble when we still have a cloud run id.
  Future<void> resumeInFlight() async {
    final jobs = <Future<void>>[];
    for (final c in List<Conversation>.from(conversations)) {
      if (_inFlight.contains(c.id)) continue;
      if (c.messages.isEmpty) continue;
      final last = c.messages.last;
      if (last.role != 'assistant') continue;
      if (last.streaming) {
        jobs.add(_resumeOne(c, last));
      } else if (c.pendingRunId != null &&
          c.pendingRunId!.isNotEmpty &&
          (last.text.trim().isEmpty || isFailedAssistantText(last.text))) {
        jobs.add(retryLast(chatId: c.id));
      }
    }
    if (jobs.isEmpty) return;
    await Future.wait(jobs);
  }

  Future<void> _resumeOne(Conversation conv, ChatMessage assistant) async {
    final api = _api;
    if (api == null) return;
    if (!_inFlight.add(conv.id)) return;
    if (errorChatId == conv.id) {
      error = null;
      errorChatId = null;
    }
    notifyListeners();
    await _withWakeLock(() async {
      try {
        final ids = await _ensureRun(api, conv);
        await _collectRun(api, conv, assistant, ids.$1, ids.$2);
      } catch (e) {
        error = friendlyNetworkError(e);
        errorChatId = conv.id;
        if (assistant.text.isEmpty || isFailedAssistantText(assistant.text)) {
          assistant.text = '出错了：$error';
        }
        assistant.streaming = false;
        if (e is RunFailedException || !isTransientNetworkError(e)) {
          conv.pendingRunId = null;
        }
      } finally {
        await _endSend(conv);
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
      errorChatId = null;
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
    if (_inFlight.contains(conv.id)) return;

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
    if (!conv.titleFrozen) {
      conv.title = conversationTitle(displayText);
    }
    conv.updatedAt = DateTime.now();

    final assistant = ChatMessage(
      id: uuid.v4(),
      role: 'assistant',
      text: '',
      streaming: true,
    );
    conv.messages.add(assistant);
    _inFlight.add(conv.id);
    error = null;
    errorChatId = null;
    notifyListeners();
    unawaited(_persist());

    final question = _questionFromUserText(trimmed);
    final userTurns = conv.messages.where((m) => m.role == 'user').length;
    final conversation = conv;
    await _withWakeLock(() async {
      await _driveTurn(
        api: api,
        conversation: conversation,
        assistant: assistant,
        question: question,
        images: images,
        userTurns: userTurns,
      );
    });
  }

  /// Resend the last user turn in place. Does not add another user bubble.
  Future<void> retryLast({String? chatId}) async {
    final api = _api;
    if (api == null) {
      error = '先在设置里填入 Cursor API Key';
      errorChatId = null;
      notifyListeners();
      return;
    }
    Conversation? conv;
    if (chatId != null) {
      for (final c in conversations) {
        if (c.id == chatId) conv = c;
      }
    } else {
      conv = active;
    }
    final target = _retryTarget(conv);
    if (target == null) return;
    if (_inFlight.contains(target.conv.id)) return;

    final images = await _imagesFor(target.user);
    target.assistant
      ..text = ''
      ..thinking = ''
      ..streaming = true;
    _inFlight.add(target.conv.id);
    error = null;
    errorChatId = null;
    notifyListeners();
    unawaited(_persist());

    final question = _questionFromUser(target.user);
    final userTurns = target.conv.messages
        .where((m) => m.role == 'user')
        .length;
    final resumeExisting =
        target.conv.agentId != null &&
        target.conv.pendingRunId != null &&
        target.conv.pendingRunId!.isNotEmpty;

    await _withWakeLock(() async {
      await _driveTurn(
        api: api,
        conversation: target.conv,
        assistant: target.assistant,
        question: question,
        images: images,
        userTurns: userTurns,
        resumeExisting: resumeExisting,
      );
    });
  }

  Future<void> _driveTurn({
    required CursorApi api,
    required Conversation conversation,
    required ChatMessage assistant,
    required String question,
    required List<PromptImage> images,
    required int userTurns,
    bool resumeExisting = false,
  }) async {
    final apiText = userTurns <= 1
        ? '$kFirstTurnPrefix${recencyPreamble()}$question'
        : '${recencyPreamble(followUp: true)}$question';
    try {
      Object? fail;
      try {
        if (resumeExisting &&
            conversation.agentId != null &&
            conversation.pendingRunId != null &&
            conversation.pendingRunId!.isNotEmpty) {
          await _collectRun(
            api,
            conversation,
            assistant,
            conversation.agentId!,
            conversation.pendingRunId!,
          );
        } else {
          if (conversation.agentId == null) {
            conversation.agentId = 'bc-${uuid.v4()}';
            unawaited(_persist());
          }
          final created = userTurns <= 1
              ? await _createFirstRun(api, conversation, apiText, images)
              : await _createFollowUp(api, conversation, apiText, images);
          conversation.agentId = created.agentId;
          conversation.pendingRunId = created.runId;
          unawaited(_persist());
          await _collectRun(
            api,
            conversation,
            assistant,
            created.agentId,
            created.runId,
          );
        }
      } catch (e) {
        fail = e;
      }
      final lostFollowUp =
          fail != null &&
          userTurns > 1 &&
          isTransientNetworkError(fail) &&
          (conversation.pendingRunId == null ||
              conversation.pendingRunId!.isEmpty);
      if (fail != null &&
          userTurns > 1 &&
          (shouldReplayAsNewAgent(fail) || lostFollowUp)) {
        try {
          assistant.text = '';
          assistant.thinking = '';
          notifyListeners();
          await _replayAsNewAgent(
            api,
            conversation,
            assistant,
            question,
            images,
          );
          fail = null;
        } catch (e) {
          fail = e;
        }
      }
      if (fail != null) {
        error = friendlyNetworkError(fail);
        errorChatId = conversation.id;
        if (assistant.text.isEmpty || isFailedAssistantText(assistant.text)) {
          assistant.text = '出错了：$error';
        }
        assistant.streaming = false;
        if (fail is RunFailedException || !isTransientNetworkError(fail)) {
          conversation.pendingRunId = null;
        }
      }
    } finally {
      await _endSend(conversation);
    }
  }

  Future<void> _endSend(Conversation conv) async {
    _inFlight.remove(conv.id);
    conv.updatedAt = DateTime.now();
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
    unawaited(_persist());
  }

  void _refreshTitle(Conversation conv) {
    if (conv.titleFrozen) return;
    ChatMessage? user;
    ChatMessage? assistant;
    for (final m in conv.messages) {
      if (user == null && m.role == 'user') user = m;
      if (m.role == 'assistant' &&
          !m.streaming &&
          m.text.trim().isNotEmpty &&
          !isFailedAssistantText(m.text)) {
        assistant = m;
        break;
      }
    }
    if (user == null) return;
    conv.title = conversationTitle(user.text, assistantText: assistant?.text);
    if (assistant != null) conv.titleFrozen = true;
  }

  Future<CreatedAgent> _createFirstRun(
    CursorApi api,
    Conversation conv,
    String apiText,
    List<PromptImage> images,
  ) async {
    Object? last;
    for (var i = 0; i < 3; i++) {
      try {
        return await api.createAgent(
          text: apiText,
          images: images,
          modelId: modelId.isEmpty ? null : modelId,
          modelParams: _paramsForApi,
          name: conv.titleFrozen || !isUsableTitle(conv.title)
              ? null
              : conv.title,
          agentId: conv.agentId,
        );
      } catch (e) {
        last = e;
        if (conv.agentId != null &&
            (isTransientNetworkError(e) ||
                (e is CursorApiException && e.status == 409))) {
          final recovered = await api.recoverCreated(conv.agentId!);
          if (recovered != null) return recovered;
        }
        if (!isTransientNetworkError(e)) break;
      }
    }
    throw last!;
  }

  Future<CreatedAgent> _createFollowUp(
    CursorApi api,
    Conversation conv,
    String apiText,
    List<PromptImage> images,
  ) async {
    final agentId = conv.agentId!;
    Object? last;
    for (var i = 0; i < 3; i++) {
      try {
        final runId = await api.createRun(
          agentId: agentId,
          text: apiText,
          images: images,
        );
        return CreatedAgent(agentId: agentId, runId: runId);
      } catch (e) {
        last = e;
        if (!isTransientNetworkError(e)) break;
      }
    }
    final e = last!;
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
    throw e;
  }

  Future<void> _replayAsNewAgent(
    CursorApi api,
    Conversation conv,
    ChatMessage assistant,
    String question,
    List<PromptImage> images,
  ) async {
    conv.agentId = 'bc-${uuid.v4()}';
    conv.pendingRunId = null;
    final apiText =
        '$kFirstTurnPrefix${recencyPreamble()}${conversationContinuityPrompt(conv.messages, question)}';
    final created = await _createFirstRun(api, conv, apiText, images);
    conv.agentId = created.agentId;
    conv.pendingRunId = created.runId;
    unawaited(_persist());
    await _collectRun(api, conv, assistant, created.agentId, created.runId);
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
        unawaited(_persist());
        return (recovered.agentId, recovered.runId);
      }
    }
    throw CursorApiException(0, '上次请求还没发出去。');
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
    unawaited(_persist());

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
      if (e is RunFailedException) rethrow;
      if (e is CursorApiException && e.isStreamGone) {
        // Run already finished; fetch the stored reply below.
      } else if (!isTransientNetworkError(e) &&
          !(e is CursorApiException && e.status == 0)) {
        rethrow;
      }
      try {
        finalText = await api.waitForRunText(agentId, runId);
      } catch (pollError) {
        if (pollError is RunFailedException) rethrow;
        if (assistant.text.trim().isNotEmpty &&
            !isFailedAssistantText(assistant.text)) {
          error = null;
          assistant.streaming = false;
          conv.pendingRunId = null;
          _refreshTitle(conv);
          return;
        }
        rethrow;
      }
    }

    if (isFailedAssistantText(finalText)) {
      throw RunFailedException('ERROR', message: finalText);
    }
    if (finalText.isNotEmpty &&
        (assistant.text.isEmpty || finalText.length >= assistant.text.length)) {
      assistant.text = finalText;
    }
    if (isFailedAssistantText(assistant.text)) {
      throw RunFailedException('ERROR', message: assistant.text);
    }
    if (assistant.text.trim().isEmpty) {
      assistant.text = '（没有文字回复）';
    }
    assistant.streaming = false;
    conv.pendingRunId = null;
    error = null;
    _refreshTitle(conv);
  }

  Future<void> _withWakeLock(Future<void> Function() fn) async {
    _wakeLocks++;
    if (_wakeLocks == 1) {
      unawaited(_setWakeLock(true));
    }
    try {
      await fn();
    } finally {
      _wakeLocks--;
      if (_wakeLocks <= 0) {
        _wakeLocks = 0;
        unawaited(_setWakeLock(false));
      }
    }
  }

  Future<void> _setWakeLock(bool on) async {
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {}
  }

  Future<void> _persist() {
    _persistChain = _persistChain
        .then((_) => _writeConversations())
        .catchError((_) => _writeConversations());
    return _persistChain;
  }

  Future<void> _writeConversations() async {
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

_RetryTarget? _retryTarget(Conversation? conv) {
  if (conv == null || conv.messages.length < 2) return null;
  final assistant = conv.messages.last;
  if (assistant.role != 'assistant' || assistant.streaming) return null;
  ChatMessage? user;
  for (final m in conv.messages.reversed) {
    if (m.role == 'user') {
      user = m;
      break;
    }
  }
  if (user == null) return null;
  if (assistant.text.trim().isEmpty || isFailedAssistantText(assistant.text)) {
    return _RetryTarget(conv, assistant, user);
  }
  return null;
}

class _RetryTarget {
  const _RetryTarget(this.conv, this.assistant, this.user);
  final Conversation conv;
  final ChatMessage assistant;
  final ChatMessage user;
}

String _questionFromUser(ChatMessage user) => _questionFromUserText(user.text);

String _questionFromUserText(String text) {
  final t = text.trim();
  if (t.isEmpty || t == '（图片）') {
    return '请看图，解释内容并回答该怎么做、为什么。';
  }
  return t;
}

Future<List<PromptImage>> _imagesFor(ChatMessage user) async {
  final out = <PromptImage>[];
  for (final path in user.imagePaths) {
    try {
      out.add(await PromptImage.fromFile(File(path)));
    } catch (_) {}
  }
  return out;
}

bool shouldReplayAsNewAgent(Object e) {
  if (e is RunFailedException) return true;
  if (e is CursorApiException) {
    if (e.status == 404) return true;
    final b = e.body.toLowerCase();
    if (b.contains('not_found') || b.contains('not found')) return true;
  }
  return false;
}

/// Rebuild the thread as a single prompt when the same agent cannot continue.
String conversationContinuityPrompt(
  List<ChatMessage> messages,
  String currentQuestion,
) {
  ChatMessage? lastUser;
  for (final m in messages.reversed) {
    if (!m.streaming && m.role == 'user') {
      lastUser = m;
      break;
    }
  }

  final buf = StringBuffer()
    ..writeln('这是同一段对话的后续。请根据下面的上下文，直接回答用户最后一句。')
    ..writeln('不要重复已经讲过的内容。')
    ..writeln();

  for (final m in messages) {
    if (identical(m, lastUser) || m.streaming) continue;
    final t = m.text.trim();
    if (t.isEmpty || isFailedAssistantText(t)) continue;
    if (m.role == 'user') {
      buf.writeln('用户：$t');
    } else if (m.role == 'assistant') {
      buf.writeln('助手：${_clipHistory(t)}');
    }
    buf.writeln();
  }
  buf.writeln('用户最后一句：$currentQuestion');
  return buf.toString();
}

String _clipHistory(String text) {
  if (text.length <= 4000) return text;
  return '${text.substring(0, 4000)}…';
}
