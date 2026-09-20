import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api/cursor_api.dart';
import 'models/models.dart';
import 'quick_prompt.dart';
import 'title.dart';
import 'voice/create_engine.dart';
import 'voice/local_sherpa_stt.dart';
import 'voice/model_store.dart';
import 'voice/voice_settings.dart';

class ChatStore extends ChangeNotifier implements VoiceStoreView {
  ChatStore({this._client, ModelStore? modelStore})
    : modelStore = modelStore ?? ModelStore();

  final CursorApi? _client;
  @override
  final ModelStore modelStore;
  @override
  VoiceMode voiceMode = VoiceMode.off;
  @override
  String localSttId = kDefaultLocalSttId;
  @override
  String cloudSttProvider = kDefaultCloudProvider;
  Map<String, CloudSttSecrets> cloudSecrets = {};
  String apiKey = '';
  String modelId = '';
  Map<String, String> modelParams = {};
  List<CursorModel> models = [];
  final List<Conversation> conversations = [];
  String? activeId;
  String? quickAgentId;
  String? nextQuickAgentId;
  bool nextQuickAgentReady = false;
  int quickAgentRotateAfter = kDefaultRotateAfter;
  int quickAgentRotateTokens = kDefaultRotateTokens;
  int quickRuleRemindEvery = kDefaultRemindEvery;
  int quickAgentLastInputTokens = 0;
  int quickAgentTurnCount = 0;
  final List<String> usedTopicCodes = [];
  final Set<String> quickAgentSentTopicIds = {};
  Future<void>? _precreateInFlight;
  int _quickGeneration = 0;
  final Set<String> _inFlight = {};
  final Set<String> _cancelRequested = {};
  final Map<String, CancelToken> _cancelTokens = {};
  List<AgentInfo> cloudAgents = [];
  bool loadingCloudAgents = false;
  String? cloudAgentsError;
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

  bool isQueued(String? id) {
    if (id == null) return false;
    for (final c in conversations) {
      if (c.id != id) continue;
      return c.messages.any((m) => m.queued);
    }
    return false;
  }

  Conversation? get quickChat => null;

  List<Conversation> get topicChats => [
    for (final c in conversations)
      if (c.kind == ConversationKind.topic) c,
  ];

  List<Conversation> get isolatedChats => [
    for (final c in conversations)
      if (c.kind == ConversationKind.isolated) c,
  ];

  @override
  CloudSttSecrets cloudSecret(String providerId) =>
      cloudSecrets[providerId] ?? const CloudSttSecrets();

  bool get voiceMicReady {
    switch (voiceMode) {
      case VoiceMode.off:
        return false;
      case VoiceMode.system:
        return Platform.isAndroid;
      case VoiceMode.local:
        return modelStore.isReady(localSttId);
      case VoiceMode.cloud:
        return cloudSecretsReady(
          cloudSttProvider,
          cloudSecret(cloudSttProvider),
        );
    }
  }

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
    voiceMode = voiceModeFromId(prefs.getString('voiceMode'));
    localSttId = prefs.getString('localSttId') ?? kDefaultLocalSttId;
    cloudSttProvider =
        prefs.getString('cloudSttProvider') ?? kDefaultCloudProvider;
    final rawCloud = prefs.getString('cloudSttSecrets');
    if (rawCloud != null && rawCloud.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawCloud) as Map<String, dynamic>;
        cloudSecrets = {
          for (final e in decoded.entries)
            e.key: CloudSttSecrets.fromJson(
              Map<String, dynamic>.from(e.value as Map),
            ),
        };
      } catch (_) {}
    }
    modelId = prefs.getString('modelId') ?? '';
    quickAgentRotateAfter = _readPrefInt(
      prefs,
      'quickAgentRotateAfter',
      kDefaultRotateAfter,
    );
    quickAgentRotateTokens = _readPrefInt(
      prefs,
      'quickAgentRotateTokens',
      kDefaultRotateTokens,
    );
    quickRuleRemindEvery = _readPrefInt(
      prefs,
      'quickRuleRemindEvery',
      kDefaultRemindEvery,
    );
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
        quickAgentId = data['quickAgentId'] as String?;
        nextQuickAgentId = data['nextQuickAgentId'] as String?;
        nextQuickAgentReady = data['nextQuickAgentReady'] == true;
        quickAgentLastInputTokens =
            (data['quickAgentLastInputTokens'] as num?)?.toInt() ?? 0;
        quickAgentTurnCount =
            (data['quickAgentTurnCount'] as num?)?.toInt() ?? 0;
        usedTopicCodes
          ..clear()
          ..addAll([
            for (final c in data['usedTopicCodes'] as List? ?? const [])
              '$c',
          ]);
        quickAgentSentTopicIds
          ..clear()
          ..addAll([
            for (final c in data['quickAgentSentTopicIds'] as List? ?? const [])
              '$c',
          ]);
      }
    } catch (_) {}
    conversations.removeWhere((c) => c.kind == ConversationKind.quick);
    _ensureTopicCodes();
    if (activeId == null ||
        !conversations.any((c) => c.id == activeId)) {
      activeId = conversations.isEmpty ? null : conversations.first.id;
    }
    _sortConversations();
    unawaited(_persist());
    notifyListeners();
    unawaited(
      modelStore.refreshAll().then((_) => notifyListeners()).catchError((_) {}),
    );
    if (models.isEmpty) unawaited(refreshModels());
    unawaited(resumeInFlight());
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiKey', apiKey.trim());
    await prefs.setString('voiceMode', voiceMode.id);
    await prefs.setString('localSttId', localSttId);
    await prefs.setString('cloudSttProvider', cloudSttProvider);
    await prefs.setString(
      'cloudSttSecrets',
      jsonEncode({
        for (final e in cloudSecrets.entries)
          if (!e.value.isEmpty) e.key: e.value.toJson(),
      }),
    );
    await prefs.setString('modelId', modelId);
    await prefs.setInt('quickAgentRotateAfter', quickAgentRotateAfter);
    await prefs.setInt('quickAgentRotateTokens', quickAgentRotateTokens);
    await prefs.setInt('quickRuleRemindEvery', quickRuleRemindEvery);
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

  void setVoiceMode(VoiceMode mode) {
    voiceMode = mode;
    if (mode == VoiceMode.system && !Platform.isAndroid) {
      voiceMode = VoiceMode.off;
    }
    notifyListeners();
    unawaited(saveSettings());
  }

  void setLocalSttId(String id) {
    localSttId = id;
    notifyListeners();
    unawaited(saveSettings());
  }

  void setCloudSttProvider(String id) {
    cloudSttProvider = id;
    notifyListeners();
    unawaited(saveSettings());
  }

  void setCloudSecret(String providerId, CloudSttSecrets secrets) {
    cloudSecrets[providerId] = secrets;
    notifyListeners();
    unawaited(saveSettings());
  }

  Future<void> downloadLocalStt(String id) async {
    await modelStore.download(id);
    notifyListeners();
  }

  Future<void> cancelLocalSttDownload(String id) async {
    await modelStore.cancelDownload(id);
    notifyListeners();
  }

  Future<void> deleteLocalStt(String id) async {
    releaseSherpaRuntime(id);
    await modelStore.deleteModel(id);
    notifyListeners();
  }

  void _sanitizeParams(CursorModel? m) {
    if (m == null) return;
    modelParams = m.alignedParams(modelParams);
  }

  int _readPrefInt(SharedPreferences prefs, String key, int fallback) {
    final v = prefs.getInt(key);
    if (v == null) return fallback;
    return v < 0 ? 0 : v;
  }

  void setQuickAgentRotateAfter(int v) {
    quickAgentRotateAfter = v < 0 ? 0 : v;
    notifyListeners();
    unawaited(saveSettings());
  }

  void setQuickAgentRotateTokens(int v) {
    quickAgentRotateTokens = v < 0 ? 0 : v;
    notifyListeners();
    unawaited(saveSettings());
  }

  void setQuickRuleRemindEvery(int v) {
    quickRuleRemindEvery = v < 0 ? 0 : v;
    notifyListeners();
    unawaited(saveSettings());
  }

  void _ensureTopicCodes() {
    for (final c in conversations) {
      if (c.kind != ConversationKind.topic) continue;
      if (isTopicCode(c.topicCode)) {
        if (!usedTopicCodes.contains(c.topicCode)) {
          usedTopicCodes.add(c.topicCode!);
        }
        continue;
      }
      c.topicCode = allocateTopicCode(usedTopicCodes);
      usedTopicCodes.add(c.topicCode!);
    }
  }

  String _nextTopicCode() {
    final code = allocateTopicCode(usedTopicCodes);
    usedTopicCodes.add(code);
    return code;
  }

  /// New topic on the shared quick agent. Does not create a Cloud Agent.
  void newChat() {
    final c = Conversation(
      id: uuid.v4(),
      title: '新对话',
      kind: ConversationKind.topic,
      topicId: uuid.v4(),
      topicCode: _nextTopicCode(),
      agentId: quickAgentId,
    );
    conversations.add(c);
    activeId = c.id;
    _sortConversations();
    notifyListeners();
    unawaited(_persist());
  }

  /// Isolated Cloud Agent. First send calls POST /v1/agents.
  void newAgentChat() {
    final c = Conversation(
      id: uuid.v4(),
      title: '新 Agent',
      kind: ConversationKind.isolated,
    );
    conversations.insert(0, c);
    activeId = c.id;
    _sortConversations();
    notifyListeners();
    unawaited(_persist());
  }

  void selectChat(String id) {
    activeId = id;
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> deleteChat(String id) async {
    Conversation? conv;
    for (final c in conversations) {
      if (c.id == id) conv = c;
    }
    if (conv == null || conv.kind == ConversationKind.quick) return;
    final agentId = conv.agentId;
    final isolated = conv.kind == ConversationKind.isolated;
    conversations.removeWhere((c) => c.id == id);
    if (activeId == id) {
      activeId = conversations.isEmpty ? null : conversations.first.id;
    }
    _sortConversations();
    notifyListeners();
    unawaited(_persist());
    if (isolated && agentId != null && agentId.isNotEmpty) {
      try {
        await _api?.deleteAgent(agentId);
      } catch (_) {}
    }
  }

  int _kindRank(ConversationKind kind) => switch (kind) {
    ConversationKind.quick => 0,
    ConversationKind.topic => 1,
    ConversationKind.isolated => 2,
  };

  void _sortConversations() {
    conversations.sort((a, b) {
      final rank = _kindRank(a.kind).compareTo(_kindRank(b.kind));
      if (rank != 0) return rank;
      return b.updatedAt.compareTo(a.updatedAt);
    });
  }

  String? _resolvedAgentId(Conversation conv) {
    if (conv.sharesQuickAgent) return quickAgentId ?? conv.agentId;
    return conv.agentId;
  }

  bool _isAgentBusy(String? agentId) {
    if (agentId == null || agentId.isEmpty) {
      return false;
    }
    for (final c in conversations) {
      if (_inFlight.contains(c.id) && c.agentId == agentId) {
        return true;
      }
    }
    return false;
  }

  bool _shouldQueue(Conversation conv) {
    if (_inFlight.contains(conv.id)) return true;
    if (conv.sharesQuickAgent) {
      // Creating the first agent leaves quickAgentId empty, so "busy by id"
      // would miss it and spawn a second shared agent.
      for (final c in conversations) {
        if (c.sharesQuickAgent && _inFlight.contains(c.id)) return true;
      }
      return false;
    }
    return _isAgentBusy(conv.agentId);
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
    bool insertNow = false,
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

    if (insertNow && _shouldQueue(conv)) {
      Conversation? busy;
      final agentId = _resolvedAgentId(conv);
      for (final c in conversations) {
        if (_inFlight.contains(c.id) &&
            (agentId == null || _resolvedAgentId(c) == agentId)) {
          busy = c;
          break;
        }
      }
      if (busy != null) await cancelGeneration(chatId: busy.id);
    }

    final displayText = trimmed.isEmpty ? '（图片）' : trimmed;
    final user = ChatMessage(
      id: uuid.v4(),
      role: 'user',
      text: displayText,
      queued: _shouldQueue(conv),
      rush: insertNow,
      imagePaths: [
        for (final img in images)
          if (img.path != null) img.path!,
      ],
    );
    conv.messages.add(user);
    if (!conv.titleFrozen) {
      conv.title = conversationTitle(displayText);
    }
    conv.updatedAt = DateTime.now();
    error = null;
    errorChatId = null;
    notifyListeners();
    unawaited(_persist());

    if (user.queued) return;
    await _launchTurn(api, conv, user, images);
  }

  Future<void> cancelGeneration({String? chatId}) async {
    Conversation? conv;
    if (chatId != null) {
      for (final c in conversations) {
        if (c.id == chatId) conv = c;
      }
    } else {
      conv = active;
    }
    if (conv == null || !_inFlight.contains(conv.id)) return;
    _cancelRequested.add(conv.id);
    _cancelTokens[conv.id]?.cancel();
    final agentId = _resolvedAgentId(conv);
    final runId = conv.pendingRunId;
    if (agentId != null && runId != null && runId.isNotEmpty) {
      try {
        await _api?.cancelRun(agentId, runId);
      } catch (_) {}
    }
  }

  void removeQueued(String messageId) {
    for (final c in conversations) {
      final before = c.messages.length;
      c.messages.removeWhere((m) => m.id == messageId && m.queued);
      if (c.messages.length != before) {
        notifyListeners();
        unawaited(_persist());
        return;
      }
    }
  }

  Future<void> _launchTurn(
    CursorApi api,
    Conversation conv,
    ChatMessage user,
    List<PromptImage> images,
  ) async {
    user.queued = false;
    user.rush = false;
    final assistant = ChatMessage(
      id: uuid.v4(),
      role: 'assistant',
      text: '',
      streaming: true,
    );
    conv.messages.add(assistant);
    _inFlight.add(conv.id);
    notifyListeners();
    unawaited(_persist());

    final question = _questionFromUserText(
      user.text == '（图片）' ? '' : user.text,
    );
    final userTurns = conv.messages.where((m) => m.role == 'user').length;
    await _withWakeLock(() async {
      await _driveTurn(
        api: api,
        conversation: conv,
        assistant: assistant,
        question: question,
        images: images,
        userTurns: userTurns,
      );
    });
  }

  Future<void> _drainQueued(String? agentId) async {
    if (agentId != null && _isAgentBusy(agentId)) return;
    ChatMessage? pick;
    Conversation? host;
    for (final c in conversations) {
      if (agentId != null && _resolvedAgentId(c) != agentId) continue;
      if (agentId == null && _resolvedAgentId(c) != null) continue;
      if (_inFlight.contains(c.id)) continue;
      for (final m in c.messages) {
        if (m.role != 'user' || !m.queued) continue;
        if (pick == null || (m.rush && !pick.rush)) {
          pick = m;
          host = c;
        }
      }
    }
    if (pick == null || host == null) return;
    final api = _api;
    if (api == null) return;
    final images = await _imagesFor(pick);
    await _launchTurn(api, host, pick, images);
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
    try {
      Object? fail;
      try {
        if (_cancelRequested.remove(conversation.id)) {
          throw RunFailedException('CANCELLED');
        }
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
          if (conversation.sharesQuickAgent) {
            await _prepareQuickSend(api, conversation);
          }
          final creatingQuick =
              conversation.sharesQuickAgent &&
              (quickAgentId == null || quickAgentId!.isEmpty);
          if (!conversation.sharesQuickAgent && conversation.agentId == null) {
            conversation.agentId = 'bc-${uuid.v4()}';
            unawaited(_persist());
          }
          final reuseAgent = conversation.sharesQuickAgent
              ? !creatingQuick
              : userTurns > 1;
          final apiText = _promptForTurn(
            conversation,
            question,
            userTurns,
            creatingQuick: creatingQuick,
          );
          if (_cancelRequested.remove(conversation.id)) {
            throw RunFailedException('CANCELLED');
          }
          final created = reuseAgent
              ? await _createFollowUp(
                  api,
                  conversation,
                  apiText,
                  images,
                  agentId: conversation.sharesQuickAgent
                      ? quickAgentId
                      : conversation.agentId,
                )
              : await _createFirstRun(
                  api,
                  conversation,
                  apiText,
                  images,
                  agentId: conversation.sharesQuickAgent
                      ? (quickAgentId ?? 'bc-${uuid.v4()}')
                      : conversation.agentId,
                );
          if (conversation.sharesQuickAgent) {
            quickAgentId = created.agentId;
          }
          conversation.agentId = created.agentId;
          conversation.pendingRunId = created.runId;
          unawaited(_persist());
          if (_cancelRequested.remove(conversation.id)) {
            try {
              await api.cancelRun(created.agentId, created.runId);
            } catch (_) {}
            throw RunFailedException('CANCELLED');
          }
          await _collectRun(
            api,
            conversation,
            assistant,
            created.agentId,
            created.runId,
          );
          if (conversation.sharesQuickAgent) {
            _noteQuickTopicSent(conversation.id);
            unawaited(
              _refreshQuickUsage(api, created.agentId, created.runId),
            );
            _maybePrecreateQuickAgent();
          }
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
          !conversation.sharesQuickAgent &&
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
        if (fail is RunFailedException && fail.status == 'CANCELLED') {
          assistant.text = fail.userMessage;
          conversation.pendingRunId = null;
          error = null;
          errorChatId = null;
        } else {
          error = friendlyNetworkError(fail);
          errorChatId = conversation.id;
          if (assistant.text.isEmpty || isFailedAssistantText(assistant.text)) {
            assistant.text = '出错了：$error';
          }
          if (fail is RunFailedException || !isTransientNetworkError(fail)) {
            conversation.pendingRunId = null;
          }
        }
        assistant.streaming = false;
      }
    } finally {
      await _endSend(conversation);
    }
  }

  Future<void> _endSend(Conversation conv) async {
    _inFlight.remove(conv.id);
    _cancelTokens.remove(conv.id);
    _cancelRequested.remove(conv.id);
    conv.updatedAt = DateTime.now();
    _sortConversations();
    notifyListeners();
    unawaited(_persist());
    unawaited(
      _drainQueued(
        conv.sharesQuickAgent ? quickAgentId : conv.agentId,
      ),
    );
  }

  bool _needsTopicReplay(Conversation conv) {
    if (!conv.sharesQuickAgent) return false;
    if (quickAgentId == null || quickAgentId!.isEmpty) return false;
    if (conv.agentId == null || conv.agentId!.isEmpty) return false;
    if (conv.agentId == quickAgentId) return false;
    return topicHasPriorTurns(conv.messages);
  }

  bool _shouldRemind() {
    if (quickRuleRemindEvery <= 0) return false;
    return (quickAgentTurnCount + 1) % quickRuleRemindEvery == 0;
  }

  bool _isContinuingOnCurrent(Conversation conv) {
    return conv.agentId != null &&
        conv.agentId == quickAgentId &&
        quickAgentSentTopicIds.contains(conv.id);
  }

  bool _shouldRotateBeforeTopic(Conversation conv) {
    if (_isContinuingOnCurrent(conv)) return false;
    // Catching up an old topic is not a new topic. Rotating first would dump
    // its history onto yet another agent and look like a random switch.
    if (_needsTopicReplay(conv)) return false;
    final n = quickAgentRotateAfter;
    final t = quickAgentRotateTokens;
    final topicHit =
        n > 0 &&
        quickAgentSentTopicIds.isNotEmpty &&
        quickAgentSentTopicIds.length >= n - 1;
    final tokenHit = t > 0 && quickAgentLastInputTokens >= t;
    return topicHit || tokenHit;
  }

  void _resetQuickGeneration() {
    quickAgentSentTopicIds.clear();
    quickAgentTurnCount = 0;
    quickAgentLastInputTokens = 0;
    _quickGeneration++;
  }

  void _noteQuickTopicSent(String id) {
    quickAgentSentTopicIds.add(id);
    quickAgentTurnCount++;
  }

  Future<void> _prepareQuickSend(CursorApi api, Conversation conv) async {
    _maybePrecreateQuickAgent();
    if (_shouldRotateBeforeTopic(conv)) {
      await _rotateQuickAgent(api);
    }
  }

  void _maybePrecreateQuickAgent() {
    if (nextQuickAgentId != null || _precreateInFlight != null) return;
    if (quickAgentId == null || quickAgentId!.isEmpty) return;
    final n = quickAgentRotateAfter;
    final t = quickAgentRotateTokens;
    final topicHit = n > 2 && quickAgentSentTopicIds.length >= n - 2;
    final tokenHit =
        t > 0 &&
        quickAgentLastInputTokens > 0 &&
        quickAgentLastInputTokens >= (t * 0.9).round();
    if (!topicHit && !tokenHit) return;
    _precreateInFlight = _precreateNextQuickAgent();
  }

  Future<void> _precreateNextQuickAgent() async {
    final api = _api;
    if (api == null) return;
    final gen = _quickGeneration;
    final id = 'bc-${uuid.v4()}';
    nextQuickAgentId = id;
    nextQuickAgentReady = false;
    unawaited(_persist());
    try {
      final created = await api.createAgent(
        text: quickAgentBootstrapPrompt(warmup: true),
        modelId: modelId.isEmpty ? null : modelId,
        modelParams: _paramsForApi,
        name: '快速对话',
        agentId: id,
      );
      if (gen != _quickGeneration) {
        _retireQuickAgent(created.agentId);
        return;
      }
      nextQuickAgentId = created.agentId;
      try {
        await api.streamRun(
          agentId: created.agentId,
          runId: created.runId,
          onDelta: (_) {},
        );
      } catch (_) {
        try {
          await api.waitForRunText(created.agentId, created.runId);
        } catch (_) {}
      }
      if (gen != _quickGeneration) {
        _retireQuickAgent(created.agentId);
        return;
      }
      nextQuickAgentReady = true;
      unawaited(_persist());
    } catch (_) {
      if (gen == _quickGeneration) {
        nextQuickAgentId = null;
        nextQuickAgentReady = false;
        unawaited(_persist());
      }
    } finally {
      if (gen == _quickGeneration) _precreateInFlight = null;
    }
  }

  Future<void> _rotateQuickAgent(CursorApi api) async {
    final old = quickAgentId;
    if (_precreateInFlight != null) {
      try {
        await _precreateInFlight;
      } catch (_) {}
    }
    if (nextQuickAgentId != null && nextQuickAgentReady) {
      quickAgentId = nextQuickAgentId;
    } else {
      quickAgentId = null;
    }
    nextQuickAgentId = null;
    nextQuickAgentReady = false;
    _resetQuickGeneration();
    unawaited(_persist());
    if (old != null && old.isNotEmpty && old != quickAgentId) {
      _retireQuickAgent(old);
    }
  }

  void _retireQuickAgent(String id) {
    unawaited(() async {
      for (var i = 0; i < 40; i++) {
        if (!_isAgentBusy(id)) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (quickAgentId == id || nextQuickAgentId == id) return;
      try {
        await _api?.deleteAgent(id);
      } catch (_) {}
    }());
  }

  Future<void> _refreshQuickUsage(
    CursorApi api,
    String agentId,
    String runId,
  ) async {
    try {
      final usage = await api.getAgentUsage(agentId, runId: runId);
      if (usage.promptish > 0) {
        quickAgentLastInputTokens = usage.promptish;
        unawaited(_persist());
        _maybePrecreateQuickAgent();
      }
    } catch (_) {}
  }

  String _promptForTurn(
    Conversation conv,
    String question,
    int userTurns, {
    bool creatingQuick = false,
  }) {
    if (!conv.sharesQuickAgent) {
      return userTurns <= 1
          ? '$kFirstTurnPrefix${recencyPreamble()}$question'
          : '${recencyPreamble(followUp: true)}$question';
    }
    final replay = _needsTopicReplay(conv);
    final remind = !creatingQuick && (replay || _shouldRemind());
    final code = isTopicCode(conv.topicCode)
        ? conv.topicCode!
        : (conv.topicCode ?? conv.id);
    final turn = quickTopicTurnPrompt(
      topicCode: code,
      question: question,
      messages: conv.messages,
      replay: replay,
      remind: remind,
      omitRecency: creatingQuick,
    );
    if (creatingQuick) {
      return '${quickAgentBootstrapPrompt()}$turn';
    }
    return turn;
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
    List<PromptImage> images, {
    String? agentId,
  }) async {
    final id = agentId ?? conv.agentId;
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
          agentId: id,
        );
      } catch (e) {
        last = e;
        if (id != null &&
            (isTransientNetworkError(e) ||
                (e is CursorApiException && e.status == 409))) {
          final recovered = await api.recoverCreated(id);
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
    List<PromptImage> images, {
    String? agentId,
  }) async {
    final id = agentId ?? conv.agentId!;
    Object? last;
    for (var i = 0; i < 3; i++) {
      try {
        final runId = await api.createRun(
          agentId: id,
          text: apiText,
          images: images,
        );
        return CreatedAgent(agentId: id, runId: runId);
      } catch (e) {
        last = e;
        if (!isTransientNetworkError(e)) break;
      }
    }
    final e = last!;
    if (isTransientNetworkError(e)) {
      try {
        final agent = await api.getAgent(id);
        final runId = agent.latestRunId;
        if (runId != null && runId.isNotEmpty) {
          final run = await api.getRun(id, runId);
          final created = DateTime.tryParse('${run['createdAt'] ?? ''}');
          final assistantAt = conv.messages.last.createdAt;
          if (created == null ||
              !created.isBefore(
                assistantAt.subtract(const Duration(seconds: 3)),
              )) {
            return CreatedAgent(agentId: id, runId: runId);
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
    conv.pendingRunId = null;
    if (conv.sharesQuickAgent) {
      final old = quickAgentId;
      final newId = 'bc-${uuid.v4()}';
      quickAgentId = newId;
      _resetQuickGeneration();
      nextQuickAgentId = null;
      nextQuickAgentReady = false;
      final code = isTopicCode(conv.topicCode)
          ? conv.topicCode!
          : (conv.topicCode ?? conv.id);
      final apiText =
          '${quickAgentBootstrapPrompt()}${quickTopicTurnPrompt(topicCode: code, question: question, messages: conv.messages, replay: topicHasPriorTurns(conv.messages), remind: true, omitRecency: true)}';
      final created = await _createFirstRun(
        api,
        conv,
        apiText,
        images,
        agentId: newId,
      );
      quickAgentId = created.agentId;
      conv.agentId = created.agentId;
      conv.pendingRunId = created.runId;
      unawaited(_persist());
      await _collectRun(api, conv, assistant, created.agentId, created.runId);
      _noteQuickTopicSent(conv.id);
      unawaited(_refreshQuickUsage(api, created.agentId, created.runId));
      if (old != null && old.isNotEmpty && old != created.agentId) {
        _retireQuickAgent(old);
      }
      return;
    }
    conv.agentId = 'bc-${uuid.v4()}';
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
      final token = CancelToken();
      _cancelTokens[conv.id] = token;
      if (_cancelRequested.contains(conv.id)) {
        token.cancel();
      }
      finalText = await api.streamRun(
        agentId: agentId,
        runId: runId,
        cancelToken: token,
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

  Future<void> refreshCloudAgents() async {
    final api = _api;
    if (api == null) {
      cloudAgentsError = '先在设置里填入 Cursor API Key';
      notifyListeners();
      return;
    }
    loadingCloudAgents = true;
    cloudAgentsError = null;
    notifyListeners();
    try {
      cloudAgents = await api.listAgents();
    } catch (e) {
      cloudAgentsError = friendlyNetworkError(e);
    } finally {
      loadingCloudAgents = false;
      notifyListeners();
    }
  }

  Future<void> deleteCloudAgent(String agentId) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.deleteAgent(agentId);
    } catch (e) {
      cloudAgentsError = friendlyNetworkError(e);
      notifyListeners();
      return;
    }
    if (quickAgentId == agentId) {
      quickAgentId = null;
      nextQuickAgentId = null;
      nextQuickAgentReady = false;
      _resetQuickGeneration();
    }
    if (nextQuickAgentId == agentId) {
      nextQuickAgentId = null;
      nextQuickAgentReady = false;
    }
    for (final c in conversations) {
      if (c.kind == ConversationKind.isolated && c.agentId == agentId) {
        c.agentId = null;
      }
    }
    cloudAgents.removeWhere((a) => a.id == agentId);
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> _writeConversations() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/conversations.json');
      await file.writeAsString(
        jsonEncode({
          'activeId': activeId,
          'quickAgentId': quickAgentId,
          'nextQuickAgentId': nextQuickAgentId,
          'nextQuickAgentReady': nextQuickAgentReady,
          'quickAgentLastInputTokens': quickAgentLastInputTokens,
          'quickAgentTurnCount': quickAgentTurnCount,
          'usedTopicCodes': usedTopicCodes,
          'quickAgentSentTopicIds': quickAgentSentTopicIds.toList(),
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
  if (e is RunFailedException) return e.status != 'CANCELLED';
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
        buf.writeln('助手：${clipPromptHistory(t)}');
      }
      buf.writeln();
    }
    buf.writeln('用户最后一句：$currentQuestion');
    return buf.toString();
}
