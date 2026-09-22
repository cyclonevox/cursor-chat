part of 'store.dart';

extension ChatStoreLane on ChatStore {
  bool _isAgentBusy(String? agentId) {
    if (agentId == null || agentId.isEmpty) return false;
    if (_precreateInFlight != null && nextQuickAgentId == agentId) return true;
    for (final c in conversations) {
      if (_inFlight.contains(c.id) && _resolvedAgentId(c) == agentId) {
        return true;
      }
    }
    return false;
  }

  bool _otherQuickInFlight(Conversation conv) {
    if (!conv.sharesQuickAgent) return false;
    for (final c in conversations) {
      if (c.id == conv.id) continue;
      if (c.sharesQuickAgent && _inFlight.contains(c.id)) return true;
    }
    return false;
  }

  /// Quick topics share one lane. An isolated chat keeps the lane it started
  /// on, so a follow-up cannot slip onto a second lane mid-turn.
  String _laneKey(Conversation conv) {
    final pinned = _laneOf[conv.id];
    if (pinned != null) return pinned;
    if (conv.sharesQuickAgent) return 'quick';
    final id = conv.agentId;
    if (id != null && id.isNotEmpty) return 'agent:$id';
    return 'chat:${conv.id}';
  }

  bool _laneBusy(Conversation conv) {
    final key = _laneKey(conv);
    if (_pumping.contains(key)) return true;
    final q = _lanes[key];
    return q != null && q.isNotEmpty;
  }

  void _enqueue(String key, _SendJob job) {
    final q = _lanes.putIfAbsent(key, () => []);
    job.seq = _jobSeq++;
    _laneOf[job.convId] = key;
    if (job.rush) {
      final at = q.indexWhere((item) => !item.rush);
      if (at < 0) {
        q.add(job);
      } else {
        q.insert(at, job);
      }
    } else {
      q.add(job);
    }
    _log(
      'enqueue',
      agentId: key,
      detail:
          '${job.kind} chat=${job.convId} rush=${job.rush} depth=${q.length}',
    );
  }

  _SendJob? _dequeue(String key) {
    final q = _lanes[key];
    if (q == null || q.isEmpty) return null;
    final job = q.removeAt(0);
    if (q.isEmpty) _lanes.remove(key);
    return job;
  }

  void _dropJobs(bool Function(_SendJob job) test) {
    for (final entry in _lanes.entries.toList()) {
      entry.value.removeWhere(test);
      if (entry.value.isEmpty) _lanes.remove(entry.key);
    }
  }

  Future<void> _pump(String key) async {
    if (!_pumping.add(key)) return;
    try {
      while (true) {
        final job = _dequeue(key);
        if (job == null) return;
        await _execute(job);
      }
    } finally {
      _pumping.remove(key);
      if (_lanes[key]?.isNotEmpty ?? false) {
        unawaited(_pump(key));
      }
    }
  }

  Future<void> _execute(_SendJob job) async {
    Conversation? conv;
    for (final c in conversations) {
      if (c.id == job.convId) conv = c;
    }
    final host = conv;
    if (host == null || _api == null) {
      job.finish();
      return;
    }
    final api = _api!;
    try {
      switch (job.kind) {
        case 'send':
          ChatMessage? user;
          for (final m in host.messages) {
            if (m.id == job.messageId) user = m;
          }
          if (user == null) break;
          final images = await _imagesFor(user);
          if (!host.messages.contains(user)) break;
          await _launchTurn(api, host, user, images);
          break;
        case 'retry':
          await _runRetry(api, host);
          break;
        case 'resume':
          if (host.messages.isEmpty) break;
          final last = host.messages.last;
          if (last.role != 'assistant' || !last.streaming) break;
          await _resumeOne(host, last);
          break;
      }
    } finally {
      job.finish();
      if (!_inFlight.contains(host.id) &&
          !(_lanes[_laneOf[host.id]]?.any((j) => j.convId == host.id) ??
              false)) {
        _laneOf.remove(host.id);
      }
    }
  }

  /// After the app is backgrounded or killed, pick up runs that already exist.
  /// Also retries a failed last bubble when we still have a cloud run id.
  Future<void> resumeInFlight() async {
    final keys = <String>{};
    for (final c in List<Conversation>.from(conversations)) {
      if (_inFlight.contains(c.id)) continue;
      if (c.messages.isEmpty) continue;
      final last = c.messages.last;
      if (last.role != 'assistant') continue;
      final key = _laneKey(c);
      if (last.streaming) {
        _enqueue(key, _SendJob.resume(c.id));
        keys.add(key);
      } else if (c.pendingRunId != null &&
          c.pendingRunId!.isNotEmpty &&
          (last.text.trim().isEmpty || isFailedAssistantText(last.text))) {
        _enqueue(key, _SendJob.retry(c.id));
        keys.add(key);
      }
    }
    if (keys.isEmpty) return;
    await Future.wait([for (final key in keys) _pump(key)]);
  }

  Future<void> _resumeOne(Conversation conv, ChatMessage assistant) async {
    final api = _api;
    if (api == null) return;
    if (!_inFlight.add(conv.id)) return;
    if (errorChatId == conv.id) {
      error = null;
      errorChatId = null;
    }
    _emit();
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
      _emit();
      return;
    }
    var conv = active;
    if (conv == null) {
      newChat();
      conv = active!;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty && images.isEmpty) return;

    final key = _laneKey(conv);
    final busy = _laneBusy(conv);
    if (insertNow && busy) {
      for (final c in conversations) {
        if (c.id == conv.id) continue;
        if (_laneKey(c) != key || !_inFlight.contains(c.id)) continue;
        await cancelGeneration(chatId: c.id);
      }
    }

    final displayText = trimmed.isEmpty ? '（图片）' : trimmed;
    final user = ChatMessage(
      id: uuid.v4(),
      role: 'user',
      text: displayText,
      queued: busy && !insertNow,
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
    _emit();
    unawaited(_persist());

    final job = _SendJob.send(conv.id, user.id, rush: insertNow);
    _enqueue(key, job);
    unawaited(_pump(key));
    if (user.queued) return;
    await job.done.future;
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
    _dropJobs((job) => job.messageId == messageId);
    for (final c in conversations) {
      final before = c.messages.length;
      c.messages.removeWhere((m) => m.id == messageId && m.queued);
      if (c.messages.length != before) {
        if (!_inFlight.contains(c.id) &&
            !(_lanes[_laneOf[c.id]]?.any((j) => j.convId == c.id) ?? false)) {
          _laneOf.remove(c.id);
        }
        _emit();
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
    _emit();
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

  /// Resend the last user turn in place. Does not add another user bubble.
  Future<void> retryLast({String? chatId}) async {
    final api = _api;
    if (api == null) {
      error = '先在设置里填入 Cursor API Key';
      errorChatId = null;
      _emit();
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
    final key = _laneKey(target.conv);
    final job = _SendJob.retry(target.conv.id);
    final queued = _laneBusy(target.conv);
    _enqueue(key, job);
    unawaited(_pump(key));
    if (queued) return;
    await job.done.future;
  }

  Future<void> _runRetry(CursorApi api, Conversation conv) async {
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
    _emit();
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
        adoptLive: true,
        fromRetry: true,
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
    bool adoptLive = false,
    bool fromRetry = false,
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
          _log(
            'turn',
            conv: conversation,
            agentId: conversation.sharesQuickAgent
                ? quickAgentId
                : conversation.agentId,
            detail: apiText,
          );
          if (_cancelRequested.remove(conversation.id)) {
            throw RunFailedException('CANCELLED');
          }
          CreatedAgent created;
          try {
            created = reuseAgent
                ? await _createFollowUp(
                    api,
                    conversation,
                    apiText,
                    images,
                    agentId: conversation.sharesQuickAgent
                        ? quickAgentId
                        : conversation.agentId,
                    adoptIfLive: adoptLive,
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
          } on CursorApiException catch (e) {
            if (!conversation.sharesQuickAgent || e.status != 404) rethrow;
            _log(
              'quick-agent-missing',
              conv: conversation,
              agentId: quickAgentId,
              detail: e.body,
            );
            _setQuickAgent(null);
            final fresh = _promptForTurn(
              conversation,
              question,
              userTurns,
              creatingQuick: true,
            );
            created = await _createFirstRun(
              api,
              conversation,
              fresh,
              images,
              agentId: 'bc-${uuid.v4()}',
            );
          }
          if (conversation.sharesQuickAgent) {
            _setQuickAgent(created.agentId);
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
            unawaited(_refreshQuickUsage(api, created.agentId, created.runId));
            _maybePrecreateQuickAgent();
          }
        }
      } on _AgentBusy {
        final n = (_busyHandoffs[conversation.id] ?? 0) + 1;
        _busyHandoffs[conversation.id] = n;
        if (n >= 3) {
          _busyHandoffs.remove(conversation.id);
          fail = RunFailedException('ERROR', message: '上一则还在回复');
        } else if (fromRetry) {
          assistant.streaming = false;
          if (assistant.text.trim().isEmpty ||
              !isFailedAssistantText(assistant.text)) {
            assistant.text = '出错了：这次没答出来。点重发再试，或新开对话。';
          }
          _enqueue(
            _laneOf[conversation.id] ?? _laneKey(conversation),
            _SendJob.retry(conversation.id),
          );
          _log(
            'retry-queued',
            conv: conversation,
            agentId: _resolvedAgentId(conversation),
            detail: 'agent busy during retry',
          );
          return;
        } else {
          _requeueOpenTurn(conversation, assistant);
          return;
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
          _emit();
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
            _log(
              'clear-pending',
              conv: conversation,
              agentId: conversation.agentId,
              runId: conversation.pendingRunId,
              detail: '$fail',
            );
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
    _emit();
    unawaited(_persist());
    _busyHandoffs.remove(conv.id);
  }

  void _requeueOpenTurn(Conversation conv, ChatMessage assistant) {
    conv.messages.remove(assistant);
    ChatMessage? user;
    for (final m in conv.messages.reversed) {
      if (m.role == 'user') {
        m.queued = true;
        user = m;
        break;
      }
    }
    if (user != null) {
      _enqueue(
        _laneOf[conv.id] ?? _laneKey(conv),
        _SendJob.send(conv.id, user.id),
      );
    }
    _log(
      'requeue-busy',
      conv: conv,
      agentId: _resolvedAgentId(conv),
      detail: 'agent busy, queued the turn',
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
    bool adoptIfLive = false,
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
      } on CursorApiException catch (e) {
        last = e;
        if (e.isAgentBusy) {
          final live = await _lookupLiveRun(api, id);
          if (live != null && _otherQuickInFlight(conv)) {
            _log(
              'agent-busy',
              conv: conv,
              agentId: id,
              runId: live.runId,
              detail: 'another topic holds the agent',
            );
            throw const _AgentBusy();
          }
          if (live != null &&
              adoptIfLive &&
              (conv.pendingRunId == null ||
                  conv.pendingRunId == live.runId ||
                  conv.pendingRunId!.isEmpty)) {
            _log('adopt-live-run', conv: conv, agentId: id, runId: live.runId);
            return live;
          }
          if (live != null) {
            _log('wait-live-run', conv: conv, agentId: id, runId: live.runId);
            await _waitUntilSettled(api, id, live.runId);
            continue;
          }
          await Future<void>.delayed(Duration(milliseconds: 350 * (i + 1)));
          continue;
        }
        if (!isTransientNetworkError(e)) break;
      } catch (e) {
        if (e is _AgentBusy) rethrow;
        last = e;
        if (!isTransientNetworkError(e)) break;
      }
    }
    final e = last!;
    if (e is CursorApiException && e.isAgentBusy) {
      _log('agent-busy', conv: conv, agentId: id, detail: e.body);
      throw const _AgentBusy();
    }
    if (isTransientNetworkError(e)) {
      try {
        final agent = await api.getAgent(id);
        final runId = agent.latestRunId;
        if (runId != null && runId.isNotEmpty) {
          final run = await api.getRun(id, runId);
          final status = run['status'] as String? ?? '';
          final created = DateTime.tryParse('${run['createdAt'] ?? ''}');
          final assistantAt = conv.messages.last.createdAt;
          final recent = created == null
              ? isLiveRunStatus(status)
              : !created.isBefore(
                  assistantAt.subtract(const Duration(seconds: 3)),
                );
          if (recent && (isLiveRunStatus(status) || status == 'FINISHED')) {
            return CreatedAgent(agentId: id, runId: runId);
          }
        }
      } catch (_) {}
    }
    throw e;
  }

  Future<CreatedAgent?> _lookupLiveRun(CursorApi api, String agentId) async {
    try {
      final agent = await api.getAgent(agentId);
      final runId = agent.latestRunId;
      if (runId == null || runId.isEmpty) return null;
      final run = await api.getRun(agentId, runId);
      final st = run['status'] as String? ?? '';
      if (!isLiveRunStatus(st)) return null;
      return CreatedAgent(agentId: agentId, runId: runId);
    } catch (e) {
      _log('lookup-live-failed', agentId: agentId, detail: '$e');
      return null;
    }
  }

  Future<void> _waitUntilSettled(
    CursorApi api,
    String agentId,
    String runId,
  ) async {
    for (var i = 0; i < 8; i++) {
      if (await _runIsTerminal(api, agentId, runId)) return;
      await Future<void>.delayed(Duration(milliseconds: 200 * (i < 3 ? 1 : 2)));
    }
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
      _setQuickAgent(newId);
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
      _setQuickAgent(created.agentId);
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
    final previous = conv.agentId;
    conv.agentId = 'bc-${uuid.v4()}';
    final apiText =
        '$kFirstTurnPrefix${recencyPreamble()}${conversationContinuityPrompt(conv.messages, question)}';
    final created = await _createFirstRun(api, conv, apiText, images);
    conv.agentId = created.agentId;
    conv.pendingRunId = created.runId;
    unawaited(_persist());
    await _collectRun(api, conv, assistant, created.agentId, created.runId);
    if (previous != null &&
        previous.isNotEmpty &&
        previous != created.agentId) {
      _retireQuickAgent(previous);
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
          _emit();
        },
        onThinking: (delta) {
          assistant.thinking += delta;
          _emit();
        },
      );
    } catch (e) {
      var recoveredLive = false;
      if (e is RunFailedException && e.status != 'CANCELLED') {
        var stillLive = false;
        try {
          final run = await api.getRun(agentId, runId);
          stillLive = isLiveRunStatus(run['status'] as String? ?? '');
        } catch (_) {}
        if (stillLive) {
          _log(
            'ignore-false-terminal',
            conv: conv,
            agentId: agentId,
            runId: runId,
            detail: '$e',
          );
          finalText = await api.waitForRunText(agentId, runId);
          recoveredLive = true;
        } else {
          rethrow;
        }
      } else if (e is CursorApiException && e.isStreamGone) {
        // Run already finished; fetch the stored reply below.
      } else if (!isTransientNetworkError(e) &&
          !(e is CursorApiException && e.status == 0)) {
        rethrow;
      }
      if (recoveredLive) {
        // Already pulled the live run's text.
      } else {
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
}
