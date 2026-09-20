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

  Conversation? get quickChat {
    for (final c in conversations) {
      if (c.kind == ConversationKind.quick) return c;
    }
    return null;
  }

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
      }
    } catch (_) {}
    _ensureQuickChat();
    if (activeId == null ||
        !conversations.any((c) => c.id == activeId)) {
      activeId = quickChat?.id ?? conversations.first.id;
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

  Conversation _ensureQuickChat() {
    final existing = quickChat;
    if (existing != null) return existing;
    final c = Conversation(
      id: uuid.v4(),
      title: '快速对话',
      kind: ConversationKind.quick,
      topicId: 'quick',
      titleFrozen: true,
      agentId: quickAgentId,
    );
    conversations.insert(0, c);
    return c;
  }

  /// New topic on the shared daily agent. Does not create a Cloud Agent.
  void newChat() {
    final quick = _ensureQuickChat();
    final c = Conversation(
      id: uuid.v4(),
      title: '新对话',
      kind: ConversationKind.topic,
      topicId: uuid.v4(),
      agentId: quickAgentId ?? quick.agentId,
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
    _ensureQuickChat();
    activeId ??= quickChat?.id;
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
    if (conv.sharesQuickAgent) return conv.agentId ?? quickAgentId;
    return conv.agentId;
  }

  bool _isAgentBusy(String? agentId) {
    if (agentId == null || agentId.isEmpty) {
      return false;
    }
    for (final c in conversations) {
      if (_inFlight.contains(c.id) && _resolvedAgentId(c) == agentId) {
        return true;
      }
    }
    return false;
  }

  bool _shouldQueue(Conversation conv) {
    if (_inFlight.contains(conv.id)) return true;
    return _isAgentBusy(_resolvedAgentId(conv));
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
      _ensureQuickChat();
      conv = active ?? quickChat;
      if (conv == null) {
        newChat();
        conv = active!;
      } else {
        activeId = conv.id;
      }
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
    final apiText = _promptForTurn(conversation, question, userTurns);
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
          final hadQuickAgent = quickAgentId != null && quickAgentId!.isNotEmpty;
          if (conversation.agentId == null) {
            conversation.agentId = conversation.sharesQuickAgent
                ? (quickAgentId ?? 'bc-${uuid.v4()}')
                : 'bc-${uuid.v4()}';
            if (conversation.sharesQuickAgent && !hadQuickAgent) {
              quickAgentId = conversation.agentId;
            }
            unawaited(_persist());
          }
          final reuseAgent = conversation.sharesQuickAgent
              ? hadQuickAgent
              : userTurns > 1;
          if (_cancelRequested.remove(conversation.id)) {
            throw RunFailedException('CANCELLED');
          }
          final created = reuseAgent
              ? await _createFollowUp(api, conversation, apiText, images)
              : await _createFirstRun(api, conversation, apiText, images);
          conversation.agentId = created.agentId;
          if (conversation.sharesQuickAgent) {
            _bindQuickAgent(created.agentId);
          }
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
    unawaited(_drainQueued(_resolvedAgentId(conv)));
  }

  void _bindQuickAgent(String agentId) {
    quickAgentId = agentId;
    for (final c in conversations) {
      if (c.sharesQuickAgent) c.agentId = agentId;
    }
  }

  String _promptForTurn(
    Conversation conv,
    String question,
    int userTurns,
  ) {
    if (!conv.sharesQuickAgent) {
      return userTurns <= 1
          ? '$kFirstTurnPrefix${recencyPreamble()}$question'
          : '${recencyPreamble(followUp: true)}$question';
    }
    return topicBoundaryPrompt(
      topicId: conv.topicId ?? conv.id,
      title: conv.title,
      messages: conv.messages,
      question: question,
      firstInTopic: userTurns <= 1,
    );
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
    if (conv.sharesQuickAgent) _bindQuickAgent(conv.agentId!);
    final apiText = conv.sharesQuickAgent
        ? topicBoundaryPrompt(
            topicId: conv.topicId ?? conv.id,
            title: conv.title,
            messages: conv.messages,
            question: question,
            firstInTopic: true,
            replay: true,
          )
        : '$kFirstTurnPrefix${recencyPreamble()}${conversationContinuityPrompt(conv.messages, question)}';
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
      for (final c in conversations) {
        if (c.sharesQuickAgent && c.agentId == agentId) c.agentId = null;
      }
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

String topicBoundaryPrompt({
  required String topicId,
  required String title,
  required List<ChatMessage> messages,
  required String question,
  required bool firstInTopic,
  bool replay = false,
}) {
  final buf = StringBuffer()
    ..writeln('[话题 $topicId｜$title]')
    ..writeln('这是快速对话里的独立话题。只根据本话题上下文回答；')
    ..writeln('不要沿用其他话题的结论，除非用户明确要求对照。')
    ..writeln();
  if (firstInTopic || replay) {
    buf.write(kFirstTurnPrefix);
    buf.write(recencyPreamble());
  } else {
    buf.write(recencyPreamble(followUp: true));
  }
  ChatMessage? lastUser;
  for (final m in messages.reversed) {
    if (!m.streaming && !m.queued && m.role == 'user') {
      lastUser = m;
      break;
    }
  }
  if (!firstInTopic || replay) {
    for (final m in messages) {
      if (identical(m, lastUser) || m.streaming || m.queued) continue;
      final t = m.text.trim();
      if (t.isEmpty || isFailedAssistantText(t)) continue;
      if (m.role == 'user') {
        buf.writeln('用户：$t');
      } else if (m.role == 'assistant') {
        buf.writeln('助手：${_clipHistory(t)}');
      }
      buf.writeln();
    }
  }
  buf.writeln('用户：$question');
  return buf.toString();
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
