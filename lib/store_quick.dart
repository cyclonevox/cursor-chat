part of 'store.dart';

extension ChatStoreQuick on ChatStore {
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

  bool _modelMismatch(Conversation conv) {
    if (!conv.sharesQuickAgent) return false;
    if (quickAgentId == null || quickAgentId!.isEmpty) return false;
    if (quickAgentModelStamp == null || quickAgentModelStamp!.isEmpty) {
      return false;
    }
    return quickAgentModelStamp != modelStamp;
  }

  bool _shouldRotateBeforeTopic(Conversation conv) {
    if (_isContinuingOnCurrent(conv)) return false;
    // Catching up an old topic is not a new topic. Rotating first would dump
    // its history onto yet another agent and look like a random switch.
    if (_needsTopicReplay(conv)) return false;
    if (_modelMismatch(conv)) return true;
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
    final stamp = modelStamp;
    final id = 'bc-${uuid.v4()}';
    nextQuickAgentId = id;
    nextQuickAgentModelStamp = stamp;
    nextQuickAgentReady = false;
    _log('precreate', agentId: id, detail: stamp);
    unawaited(_persist());
    try {
      final created = await api.createAgent(
        text: quickAgentBootstrapPrompt(warmup: true),
        modelId: modelId.isEmpty ? null : modelId,
        modelParams: _paramsForApi,
        name: '快速对话',
        agentId: id,
      );
      if (gen != _quickGeneration || stamp != modelStamp) {
        _retireQuickAgent(created.agentId);
        return;
      }
      nextQuickAgentId = created.agentId;
      nextQuickAgentModelStamp = stamp;
      try {
        await api.streamRun(
          agentId: created.agentId,
          runId: created.runId,
          onDelta: (_) {},
        );
      } catch (e) {
        if (e is! RunFailedException) {
          try {
            await api.waitForRunText(created.agentId, created.runId);
          } catch (_) {}
        }
      }
      if (gen != _quickGeneration || stamp != modelStamp) {
        _retireQuickAgent(created.agentId);
        return;
      }
      if (!await _runIsTerminal(api, created.agentId, created.runId)) {
        try {
          await api.waitForRunText(created.agentId, created.runId);
        } catch (_) {}
      }
      if (gen != _quickGeneration || stamp != modelStamp) {
        _retireQuickAgent(created.agentId);
        return;
      }
      if (!await _runIsTerminal(api, created.agentId, created.runId)) {
        _log(
          'precreate-not-ready',
          agentId: created.agentId,
          runId: created.runId,
          detail: 'warmup run still live',
        );
        nextQuickAgentId = null;
        nextQuickAgentReady = false;
        nextQuickAgentModelStamp = null;
        unawaited(_persist());
        return;
      }
      nextQuickAgentReady = true;
      _log('precreate-ready', agentId: created.agentId, runId: created.runId);
      unawaited(_persist());
    } catch (_) {
      if (gen == _quickGeneration) {
        nextQuickAgentId = null;
        nextQuickAgentReady = false;
        nextQuickAgentModelStamp = null;
        unawaited(_persist());
      }
    } finally {
      if (gen == _quickGeneration) _precreateInFlight = null;
    }
  }

  Future<bool> _runIsTerminal(
    CursorApi api,
    String agentId,
    String runId,
  ) async {
    try {
      final run = await api.getRun(agentId, runId);
      final st = run['status'] as String? ?? '';
      if (st.isEmpty) return false;
      return !isLiveRunStatus(st);
    } catch (_) {
      return false;
    }
  }

  Future<void> _rotateQuickAgent(CursorApi api) async {
    final old = quickAgentId;
    if (_precreateInFlight != null) {
      try {
        await _precreateInFlight;
      } catch (_) {}
    }
    final standby = nextQuickAgentId;
    final standbyReady = nextQuickAgentReady;
    final standbyStamp = nextQuickAgentModelStamp;
    nextQuickAgentId = null;
    nextQuickAgentReady = false;
    nextQuickAgentModelStamp = null;
    _resetQuickGeneration();
    final stampOk = standbyStamp != null && standbyStamp == modelStamp;
    if (standby != null && standbyReady && stampOk) {
      final live = await _lookupLiveRun(api, standby);
      if (live != null) {
        _log('rotate-wait', agentId: standby, runId: live.runId);
        await _waitUntilSettled(api, standby, live.runId);
      }
      if (await _lookupLiveRun(api, standby) != null) {
        _log('rotate-skip-busy', agentId: standby);
        _setQuickAgent(null);
        _retireQuickAgent(standby);
      } else {
        _setQuickAgent(standby);
        _log('rotate', agentId: standby, detail: modelStamp);
      }
    } else {
      _setQuickAgent(null);
      _log(
        'rotate',
        agentId: old,
        detail: standby == null ? 'no standby' : 'standby not usable',
      );
      if (standby != null && standby.isNotEmpty && standby != old) {
        _retireQuickAgent(standby);
      }
    }
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
}
