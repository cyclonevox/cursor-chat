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
import 'run_log.dart';
import 'title.dart';
import 'voice/create_engine.dart';
import 'voice/local_sherpa_stt.dart';
import 'voice/model_store.dart';
import 'voice/voice_settings.dart';

part 'store_lane.dart';
part 'store_quick.dart';

class ChatStore extends ChangeNotifier implements VoiceStoreView {
  ChatStore({this._client, ModelStore? modelStore, RunLog? runLog})
    : modelStore = modelStore ?? ModelStore(),
      runLog = runLog ?? RunLog();

  final CursorApi? _client;
  final RunLog runLog;
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
  String? quickAgentModelStamp;
  String? nextQuickAgentModelStamp;
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
  final Map<String, int> _busyHandoffs = {};
  final Map<String, List<_SendJob>> _lanes = {};
  final Set<String> _pumping = {};
  final Map<String, String> _laneOf = {};
  int _jobSeq = 0;
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

  /// Model id plus sorted params. A quick agent keeps the stamp it was born with.
  String get modelStamp {
    final keys = modelParams.keys.toList()..sort();
    return '$modelId|${[for (final k in keys) '$k=${modelParams[k]}'].join(',')}';
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
    final client = _client;
    if (client != null) {
      client.onLog ??= _onApiLog;
      return client;
    }
    final key = apiKey.trim();
    if (key.isEmpty) return null;
    return CursorApi(apiKey: key, onLog: _onApiLog);
  }

  void _onApiLog(String event, Map<String, Object?> fields) {
    _log(
      event,
      agentId: fields['agentId'] as String?,
      runId: fields['runId'] as String?,
      detail: fields.entries
          .where((e) => e.key != 'agentId' && e.key != 'runId')
          .map((e) => '${e.key}=${e.value}')
          .join(' '),
    );
  }

  void _log(
    String event, {
    Conversation? conv,
    String? agentId,
    String? runId,
    String? detail,
  }) {
    final params = modelStamp.contains('|')
        ? modelStamp.substring(modelStamp.indexOf('|') + 1)
        : '';
    runLog.add(
      RunLogEntry(
        time: DateTime.now(),
        event: event,
        conversationId: conv?.id,
        topicCode: conv?.topicCode,
        agentId: agentId,
        runId: runId ?? conv?.pendingRunId,
        modelId: modelId,
        modelParams: params,
        detail: clipLog(detail),
      ),
    );
  }

  Future<String> exportRunLog() => runLog.exportText();

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
            for (final c in data['usedTopicCodes'] as List? ?? const []) '$c',
          ]);
        quickAgentSentTopicIds
          ..clear()
          ..addAll([
            for (final c in data['quickAgentSentTopicIds'] as List? ?? const [])
              '$c',
          ]);
        quickAgentModelStamp = data['quickAgentModelStamp'] as String?;
        nextQuickAgentModelStamp = data['nextQuickAgentModelStamp'] as String?;
        if (quickAgentId != null &&
            quickAgentId!.isNotEmpty &&
            (quickAgentModelStamp == null || quickAgentModelStamp!.isEmpty)) {
          quickAgentModelStamp = modelStamp;
        }
      }
    } catch (_) {}
    unawaited(runLog.load());
    conversations.removeWhere((c) => c.kind == ConversationKind.quick);
    _ensureTopicCodes();
    if (activeId == null || !conversations.any((c) => c.id == activeId)) {
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
    _onModelChoiceChanged();
    notifyListeners();
    if (persist) unawaited(saveSettings());
  }

  void setParam(String id, String value) {
    modelParams[id] = value;
    _onModelChoiceChanged();
    notifyListeners();
    unawaited(saveSettings());
  }

  void _onModelChoiceChanged() {
    _log('model-choice', detail: modelStamp);
    if (nextQuickAgentId == null || nextQuickAgentId!.isEmpty) return;
    if (nextQuickAgentModelStamp == modelStamp) return;
    _dropStandby('model-changed');
  }

  void _setQuickAgent(String? id) {
    quickAgentId = id;
    if (id == null || id.isEmpty) {
      quickAgentModelStamp = null;
    } else {
      quickAgentModelStamp = modelStamp;
    }
  }

  void _dropStandby(String reason) {
    final id = nextQuickAgentId;
    final inflight = _precreateInFlight != null;
    nextQuickAgentId = null;
    nextQuickAgentReady = false;
    nextQuickAgentModelStamp = null;
    _quickGeneration++;
    _log('drop-standby', agentId: id, detail: reason);
    if (id != null && id.isNotEmpty && !inflight) {
      _retireQuickAgent(id);
    }
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

  /// Extensions in this library cannot call [notifyListeners] directly.
  void _emit() => notifyListeners();

  void clearError() {
    error = null;
    errorChatId = null;
    notifyListeners();
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
      _setQuickAgent(null);
      nextQuickAgentId = null;
      nextQuickAgentReady = false;
      nextQuickAgentModelStamp = null;
      _resetQuickGeneration();
    }
    if (nextQuickAgentId == agentId) {
      nextQuickAgentId = null;
      nextQuickAgentReady = false;
      nextQuickAgentModelStamp = null;
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
          'quickAgentModelStamp': quickAgentModelStamp,
          'nextQuickAgentModelStamp': nextQuickAgentModelStamp,
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

class _SendJob {
  _SendJob.send(this.convId, this.messageId, {this.rush = false})
    : kind = 'send';
  _SendJob.retry(this.convId) : kind = 'retry', messageId = null, rush = false;
  _SendJob.resume(this.convId)
    : kind = 'resume',
      messageId = null,
      rush = false;

  final String kind;
  final String convId;
  final String? messageId;
  final bool rush;
  int seq = 0;
  final Completer<void> done = Completer<void>();

  void finish() {
    if (!done.isCompleted) done.complete();
  }
}

class _AgentBusy implements Exception {
  const _AgentBusy();
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
