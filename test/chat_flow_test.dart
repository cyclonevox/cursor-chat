import 'dart:async';

import 'package:cursor_chat/api/cursor_api.dart';
import 'package:cursor_chat/main.dart';
import 'package:cursor_chat/models/models.dart';
import 'package:cursor_chat/quick_prompt.dart';
import 'package:cursor_chat/store.dart';
import 'package:cursor_chat/title.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_cursor_api.dart';

Future<void> _until(
  bool Function() ok, {
  WidgetTester? tester,
  int ticks = 200,
}) async {
  for (var i = 0; i < ticks; i++) {
    if (ok()) return;
    if (tester != null) {
      await tester.pump(const Duration(milliseconds: 10));
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  fail('timed out waiting for condition');
}

Future<void> _typeAndSend(WidgetTester tester, String text) async {
  final input = find.byKey(const Key('composer-input'));
  expect(tester.widget<TextField>(input).enabled, isTrue);
  await tester.enterText(input, text);
  await tester.pump();
  expect(
    tester.widget<TextField>(input).controller!.text,
    text,
    reason: '输入框没有收到文字',
  );
  final send = find.byKey(const Key('composer-send'));
  final btn = tester.widget<IconButton>(send);
  expect(btn.onPressed, isNotNull, reason: '发送按钮被禁用了');
  btn.onPressed!();
  await tester.pump();
}

Future<void> _openDrawer(WidgetTester tester) async {
  tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('two chats can stream at the same time', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..addAll([
        Conversation(id: 'a', title: '对话A'),
        Conversation(id: 'b', title: '对话B'),
      ]);
    store.activeId = 'a';

    final sendA = store.send(text: '这题为啥要先通分？');
    await _until(() => api.streams.containsKey('run-1'));
    expect(store.isSending('a'), isTrue);
    expect(store.sending, isTrue);

    store.selectChat('b');
    expect(store.sending, isFalse);
    expect(store.isSending('a'), isTrue);

    final sendB = store.send(text: '什么是哈希碰撞');
    await _until(() => api.streams.containsKey('run-2'));
    expect(store.isSending('b'), isTrue);
    expect(store.isSending('a'), isTrue);
    expect(api.createdPrompts, hasLength(2));

    api.finish('run-2', '哈希碰撞是指不同输入映射到同一哈希值。');
    await sendB;
    expect(store.isSending('b'), isFalse);
    expect(store.isSending('a'), isTrue);
    expect(
      store.conversations.where((c) => c.id == 'b').first.title,
      isNot('什么是哈希碰撞'),
    );
    expect(
      looksLikeQuestion(
        store.conversations.where((c) => c.id == 'b').first.title,
      ),
      isFalse,
    );

    api.finish('run-1', '通分是为了把分母对齐。');
    await sendA;
    expect(store.isSending('a'), isFalse);
    final a = store.conversations.where((c) => c.id == 'a').first;
    expect(a.title, isNot('这题为啥要先通分？'));
    expect(looksLikeQuestion(a.title), isFalse);
  });

  test('topic prompt uses a stable #T- code without dumping follow-up history', () {
    final prompt = quickTopicTurnPrompt(
      topicCode: '#T-ABCDEF',
      question: '那穿什么',
      messages: [
        ChatMessage(id: 'u1', role: 'user', text: '今天热不热'),
        ChatMessage(id: 'a1', role: 'assistant', text: '有点热。'),
        ChatMessage(id: 'u2', role: 'user', text: '那穿什么'),
      ],
    );
    expect(prompt, contains('#T-ABCDEF'));
    expect(prompt, contains('用户：那穿什么'));
    expect(prompt.contains('今天热不热'), isFalse);
    expect(prompt.contains('独立话题'), isFalse);
  });

  test('continuity prompt keeps prior Q&A and drops error bubbles', () {
    final prompt = conversationContinuityPrompt([
      ChatMessage(id: 'u1', role: 'user', text: '你这个可微里的 r 怎么来的？'),
      ChatMessage(id: 'a1', role: 'assistant', text: 'r 是到原点的距离。'),
      ChatMessage(id: 'u2', role: 'user', text: '我没太明白，这个证明可微，到底怎么个流程？'),
      ChatMessage(id: 'a2', role: 'assistant', text: '', streaming: true),
    ], '我没太明白，这个证明可微，到底怎么个流程？');
    expect(prompt, contains('这是同一段对话的后续'));
    expect(prompt, contains('r 是到原点的距离'));
    expect(prompt, contains('用户最后一句：我没太明白，这个证明可微，到底怎么个流程？'));
    expect(prompt.contains('运行结束'), isFalse);
  });

  test('same chat queues a second send while loading', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..add(Conversation(id: 'a', title: '对话A'));
    store.activeId = 'a';

    final first = store.send(text: '牛顿第一定律是什么');
    await _until(() => api.createdPrompts.length == 1);
    await store.send(text: '第二句先排队');
    expect(api.createdPrompts, hasLength(1));
    expect(store.active!.messages.where((m) => m.role == 'user'), hasLength(2));
    expect(store.active!.messages.where((m) => m.queued), hasLength(1));

    api.finish('run-1', '牛顿第一定律是指惯性定律。');
    await first;
    await _until(() => api.createdPrompts.length == 2);
    expect(store.active!.messages.where((m) => m.queued), isEmpty);
    api.finish(store.active!.pendingRunId!, '这是排队后的第二句。');
    await _until(() => !store.isSending('a'));
    expect(store.active!.messages.last.text, contains('排队后'));
  });

  test('cancel stops the current run', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..add(Conversation(id: 'a', title: '对话A'));
    store.activeId = 'a';

    final first = store.send(text: '牛顿第一定律是什么');
    await _until(() => store.active!.pendingRunId != null);
    await store.cancelGeneration();
    await first;
    expect(api.cancelledRuns, isNotEmpty);
    expect(store.active!.messages.last.text, contains('取消'));
    expect(store.isSending('a'), isFalse);
  });

  test(
    'new topic reuses the quick agent instead of creating another',
    () async {
      final api = FakeCursorApi();
      final store = ChatStore(client: api);
      store.apiKey = 'k';
      store.conversations.clear();
      store.newChat();
      expect(store.active!.kind, ConversationKind.topic);
      expect(isTopicCode(store.active!.topicCode), isTrue);

      final first = store.send(text: '今天天气怎么样');
      await _until(() => store.active!.pendingRunId != null);
      final agent = store.quickAgentId;
      expect(agent, isNotNull);
      expect(api.createdPrompts, hasLength(1));
      expect(api.createdPrompts.last, contains('#T-'));
      expect(api.createdPrompts.last, contains('你会同时处理多个互不干扰的话题'));
      api.finish(store.active!.pendingRunId!, '今天不错。');
      await first;

      store.newChat();
      expect(store.active!.kind, ConversationKind.topic);
      final second = store.send(text: '换个话题，1+1等于几');
      await _until(() => store.active!.pendingRunId != null);
      expect(store.quickAgentId, agent);
      expect(store.active!.agentId, agent);
      expect(api.createdPrompts, hasLength(2));
      expect(api.createdPrompts.last, contains('#T-'));
      expect(api.createdPrompts.last, contains('1+1等于几'));
      expect(api.createdPrompts.last.contains('今天天气'), isFalse);
      expect(
        store.topicChats.map((c) => c.topicCode).toSet(),
        hasLength(2),
      );
      api.finish(store.active!.pendingRunId!, '2');
      await second;
    },
  );

  test('newAgentChat still creates a separate cloud agent', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations.clear();
    store.newChat();
    final daily = store.send(text: '日常一句');
    await _until(() => store.active!.pendingRunId != null);
    final quick = store.quickAgentId;
    api.finish(store.active!.pendingRunId!, '收到');
    await daily;

    store.newAgentChat();
    expect(store.active!.kind, ConversationKind.isolated);
    final isolated = store.send(text: '这是隔离对话');
    await _until(() => store.active!.pendingRunId != null);
    expect(store.active!.agentId, isNot(quick));
    api.finish(store.active!.pendingRunId!, '隔离答复');
    await isolated;
  });

  test('deleting an isolated chat deletes the cloud agent', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..add(
        Conversation(
          id: 'iso',
          title: '隔离',
          kind: ConversationKind.isolated,
          agentId: 'bc-gone',
        ),
      );
    store.activeId = 'iso';
    await store.deleteChat('iso');
    expect(api.deletedAgents, contains('bc-gone'));
    expect(store.conversations.where((c) => c.kind == ConversationKind.quick), isEmpty);
  });

  testWidgets('typing in B works while A is still loading', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..addAll([
        Conversation(id: 'a', title: '对话A'),
        Conversation(id: 'b', title: '对话B'),
      ]);
    store.activeId = 'a';

    await tester.pumpWidget(ChatApp(store: store));

    await _typeAndSend(tester, '这题为啥要先通分？');
    await _until(() => store.isSending('a'), tester: tester);
    await _until(
      () =>
          store.conversations.where((c) => c.id == 'a').first.pendingRunId !=
          null,
      tester: tester,
    );
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byKey(const Key('composer-input'))).enabled,
      isTrue,
      reason: '回复中仍要能输入，方便排队',
    );

    await _openDrawer(tester);
    expect(find.text('回复中…'), findsWidgets);
    await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text('对话B')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.activeId, 'b');
    expect(
      tester.widget<TextField>(find.byKey(const Key('composer-input'))).enabled,
      isTrue,
      reason: 'A 还在载入时，B 必须能输入',
    );

    await _typeAndSend(tester, '什么是哈希碰撞');
    await _until(() => store.isSending('b'), tester: tester);
    await _until(
      () =>
          store.conversations.where((c) => c.id == 'b').first.pendingRunId !=
          null,
      tester: tester,
    );
    await tester.pump();

    expect(store.isSending('a'), isTrue);
    expect(store.isSending('b'), isTrue);
    expect(
      store.conversations
          .where((c) => c.id == 'b')
          .first
          .messages
          .where((m) => m.role == 'user' && m.text.contains('哈希碰撞')),
      isNotEmpty,
    );

    final runB = store.conversations
        .where((c) => c.id == 'b')
        .first
        .pendingRunId!;
    final runA = store.conversations
        .where((c) => c.id == 'a')
        .first
        .pendingRunId!;
    api.finish(runB, '哈希碰撞是指不同输入映射到同一哈希值。');
    await tester.pump();
    await _until(() => !store.isSending('b'), tester: tester);
    await tester.pump();

    final b = store.conversations.where((c) => c.id == 'b').first;
    expect(b.title, isNot('什么是哈希碰撞'));
    expect(b.messages.last.text, contains('哈希碰撞是指'));

    await _openDrawer(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.textContaining('通分'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.activeId, 'a');
    expect(
      tester.widget<TextField>(find.byKey(const Key('composer-input'))).enabled,
      isTrue,
    );

    api.finish(runA, '通分是为了把分母对齐。');
    await tester.pump();
    await _until(() => !store.isSending('a'), tester: tester);
    await tester.pump();

    final a = store.conversations.where((c) => c.id == 'a').first;
    expect(a.title, isNot('这题为啥要先通分？'));
    expect(looksLikeQuestion(a.title), isFalse);
  });

  testWidgets('new chat, settings, delete still work while A loads', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..addAll([
        Conversation(id: 'a', title: '对话A'),
        Conversation(id: 'b', title: '对话B'),
      ]);
    store.activeId = 'a';

    await tester.pumpWidget(ChatApp(store: store));
    await _typeAndSend(tester, '今天是星期几');
    await _until(() => store.isSending('a'), tester: tester);
    await _until(
      () =>
          store.conversations.where((c) => c.id == 'a').first.pendingRunId !=
          null,
      tester: tester,
    );
    await tester.pump();

    await _openDrawer(tester);
    await tester.tap(find.byTooltip('新对话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.activeId, isNot('a'));
    expect(
      tester.widget<TextField>(find.byKey(const Key('composer-input'))).enabled,
      isTrue,
    );

    await _typeAndSend(tester, '牛顿第一定律是什么');
    await _until(() => store.isSending(store.activeId), tester: tester);
    await _until(() => api.streams.length >= 2, tester: tester);
    expect(store.isSending('a'), isTrue);

    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Cursor API Key'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await _openDrawer(tester);
    final beforeDelete = store.conversations.length;
    await tester.tap(
      find
          .descendant(
            of: find.byType(Drawer),
            matching: find.byIcon(Icons.delete_outline),
          )
          .first,
    );
    await tester.pump();
    expect(store.conversations.length, beforeDelete - 1);
    expect(store.isSending('a'), isTrue);

    api.finishAll();
    await tester.pump();
    await _until(() => !store.isSending('a'), tester: tester);
  });

  test(
    'follow-up ERROR is not shown as a reply; history is replayed',
    () async {
      final api = FakeCursorApi();
      final store = ChatStore(client: api);
      store.apiKey = 'k';
      store.conversations
        ..clear()
        ..add(Conversation(id: 'a', title: '可微证明', titleFrozen: true));
      store.activeId = 'a';

      final first = store.send(text: '你这个可微里的 r 怎么来的？');
      await _until(() => store.active!.pendingRunId != null);
      api.finish(store.active!.pendingRunId!, '把 (x,y) 换成极坐标，r 就是到原点的距离。');
      await first;
      expect(store.active!.messages.last.text, contains('极坐标'));

      final follow = store.send(text: '我没太明白，这个证明可微，到底怎么个流程？');
      await _until(() => store.active!.pendingRunId != null);
      final followRun = store.active!.pendingRunId!;
      api.fail(followRun);
      await _until(() => api.createdPrompts.length >= 3);
      expect(store.active!.messages.last.text.contains('运行结束：ERROR'), isFalse);
      expect(api.createdPrompts.last, contains('这是同一段对话的后续'));
      expect(api.createdPrompts.last, contains('我没太明白，这个证明可微'));
      expect(api.createdPrompts.last, contains('极坐标'));

      final replayRun = store.active!.pendingRunId!;
      expect(replayRun, isNot(followRun));
      api.finish(replayRun, '可微就是看误差除以 r 是否趋于 0。按公式把分子除以 r 即可。');
      await follow;

      expect(store.active!.messages.last.text, contains('误差除以 r'));
      expect(
        store.active!.messages.where((m) => m.text.contains('运行结束')),
        isEmpty,
      );
    },
  );

  testWidgets('screenshot path: follow-up ERROR does not stay on screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..add(Conversation(id: 'a', title: '可微证明', titleFrozen: true));
    store.activeId = 'a';

    await tester.pumpWidget(ChatApp(store: store));
    await _typeAndSend(tester, '你这个可微里的 r 怎么来的？');
    await _until(() => store.active!.pendingRunId != null, tester: tester);
    api.finish(store.active!.pendingRunId!, '把 (x,y) 换成极坐标，r 就是到原点的距离。');
    await tester.pump();
    await _until(() => !store.isSending('a'), tester: tester);
    await tester.pump();

    await _typeAndSend(tester, '我没太明白，这个证明可微，到底怎么个流程？');
    await _until(() => store.active!.pendingRunId != null, tester: tester);
    api.fail(store.active!.pendingRunId!);
    await tester.pump();
    await _until(() => api.createdPrompts.length >= 3, tester: tester);
    await tester.pump();

    expect(find.text('运行结束：ERROR'), findsNothing);
    expect(find.byKey(const Key('composer-stop')), findsOneWidget);

    api.finish(store.active!.pendingRunId!, '可微就是看误差除以 r 是否趋于 0。');
    await tester.pump();
    await _until(() => !store.isSending('a'), tester: tester);
    await tester.pump();

    expect(find.textContaining('误差除以 r'), findsOneWidget);
    expect(find.text('运行结束：ERROR'), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(const Key('composer-input'))).enabled,
      isTrue,
    );
  });

  test('follow-up network drop dumps local session into a new agent', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..add(Conversation(id: 'a', title: '可微证明', titleFrozen: true));
    store.activeId = 'a';

    final first = store.send(text: '你这个可微里的 r 怎么来的？');
    await _until(() => store.active!.pendingRunId != null);
    api.finish(store.active!.pendingRunId!, '把 (x,y) 换成极坐标，r 就是到原点的距离。');
    await first;

    api.failRuns = true;
    final follow = store.send(text: '你这个和答案写的不一样啊');
    await _until(() => api.createdPrompts.length >= 2);
    expect(api.createdPrompts.last, contains('这是同一段对话的后续'));
    expect(api.createdPrompts.last, contains('你这个和答案写的不一样啊'));
    expect(api.createdPrompts.last, contains('极坐标'));

    api.failRuns = false;
    final replayRun = store.active!.pendingRunId!;
    api.finish(replayRun, '按书上的写法，先写定义再估计余项。');
    await follow;
    expect(store.active!.messages.last.text, contains('按书上的写法'));
    expect(store.active!.messages.where((m) => m.role == 'user'), hasLength(2));
  });

  test('network drop keeps run id; retryLast pulls the reply back', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..add(Conversation(id: 'a', title: '对话A'));
    store.activeId = 'a';

    api.nextStreamError = CursorApiException(0, 'Connection reset');
    api.nextWaitError = CursorApiException(0, 'Connection reset');
    await store.send(text: '牛顿第一定律是什么');
    expect(store.active!.pendingRunId, isNotNull);
    expect(store.active!.messages.last.text, contains('网络中断'));
    expect(store.canRetryLast, isTrue);
    expect(store.active!.messages.where((m) => m.role == 'user'), hasLength(1));

    final runId = store.active!.pendingRunId!;
    final retry = store.retryLast();
    await _until(() => store.isSending('a'));
    api.finish(runId, '惯性定律。');
    await retry;
    expect(store.active!.messages.last.text, contains('惯性定律'));
    expect(store.active!.messages.where((m) => m.role == 'user'), hasLength(1));
    expect(store.canRetryLast, isFalse);
  });

  test(
    'resumeInFlight recovers a failed bubble that still has a run id',
    () async {
      final api = FakeCursorApi();
      final store = ChatStore(client: api);
      store.apiKey = 'k';
      store.conversations
        ..clear()
        ..add(Conversation(id: 'a', title: '对话A'));
      store.activeId = 'a';

      api.nextStreamError = CursorApiException(0, 'Connection reset');
      api.nextWaitError = CursorApiException(0, 'Connection reset');
      await store.send(text: '什么是哈希碰撞');
      expect(store.active!.messages.last.streaming, isFalse);
      final runId = store.active!.pendingRunId!;

      final resumed = store.resumeInFlight();
      await _until(() => store.isSending('a'));
      api.finish(runId, '不同输入映射到同一哈希值。');
      await resumed;
      expect(store.active!.messages.last.text, contains('不同输入映射'));
    },
  );

  testWidgets('failed reply shows resend and retries without duplicating', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..add(Conversation(id: 'a', title: '可微证明', titleFrozen: true));
    store.activeId = 'a';

    await tester.pumpWidget(ChatApp(store: store));
    await _typeAndSend(tester, '你这个可微里的 r 怎么来的？');
    await _until(() => store.active!.pendingRunId != null, tester: tester);
    api.finish(store.active!.pendingRunId!, 'r 是到原点的距离。');
    await tester.pump();
    await _until(() => !store.isSending('a'), tester: tester);
    await tester.pump();

    api.nextStreamError = CursorApiException(0, 'Connection reset');
    api.nextWaitError = CursorApiException(0, 'Connection reset');
    await _typeAndSend(tester, '你这个和答案写的不一样啊');
    await tester.pump();
    await _until(() => !store.isSending('a'), tester: tester);
    await tester.pump();

    expect(find.text('重发'), findsWidgets);
    expect(find.byTooltip('重发'), findsOneWidget);
    expect(store.active!.messages.where((m) => m.role == 'user'), hasLength(2));
    final runId = store.active!.pendingRunId;
    expect(runId, isNotNull);

    await tester.tap(find.byTooltip('重发'));
    await tester.pump();
    await _until(() => store.isSending('a'), tester: tester);
    api.finish(runId!, '按书上的写法来。');
    await tester.pump();
    await _until(() => !store.isSending('a'), tester: tester);
    await tester.pump();

    expect(find.textContaining('按书上的写法来'), findsOneWidget);
    expect(store.active!.messages.where((m) => m.role == 'user'), hasLength(2));
    expect(find.byTooltip('重发'), findsNothing);
  });

  test('nth new topic rotates the quick agent and old topics replay', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.quickAgentRotateAfter = 3;
    store.quickAgentRotateTokens = 0;
    store.conversations.clear();

    Future<void> talk(String text, String reply) async {
      final fut = store.send(text: text);
      await _until(() => store.active!.pendingRunId != null);
      api.finish(store.active!.pendingRunId!, reply);
      await fut;
    }

    store.newChat();
    await talk('天气怎么样', '晴');
    final firstAgent = store.quickAgentId;
    final firstTopic = store.active!;
    expect(firstAgent, isNotNull);
    expect(firstTopic.agentId, firstAgent);

    store.newChat();
    await talk('1+1', '2');
    expect(store.quickAgentId, firstAgent);

    store.newChat();
    await talk('现在几点', '三点');
    expect(store.quickAgentId, isNot(firstAgent));
    expect(store.active!.agentId, store.quickAgentId);
    expect(
      api.createdPrompts.any((p) => p.contains(kQuickAgentWarmup)),
      isTrue,
    );

    store.selectChat(firstTopic.id);
    await talk('明天呢', '也晴');
    expect(api.createdPrompts.last, contains('话题回溯'));
    expect(api.createdPrompts.last, contains('天气怎么样'));
    expect(api.createdPrompts.last, contains('#T-'));
    expect(store.active!.agentId, store.quickAgentId);
  });

  test('in-flight topic queues another topic instead of a second agent', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations.clear();

    store.newChat();
    final first = store.send(text: '天气怎么样');
    await _until(() => store.active!.pendingRunId != null);
    final firstId = store.active!.id;
    final firstAgent = store.quickAgentId;

    store.newChat();
    unawaited(store.send(text: '1+1等于几'));
    await _until(() => store.active!.messages.any((m) => m.queued));
    expect(api.createdPrompts, hasLength(1));
    expect(store.quickAgentId, firstAgent);

    api.finish(
      store.conversations.firstWhere((c) => c.id == firstId).pendingRunId!,
      '晴',
    );
    await first;
    await _until(() => api.createdPrompts.length == 2);
    expect(store.quickAgentId, firstAgent);
    expect(store.active!.agentId, firstAgent);
    api.finish(store.active!.pendingRunId!, '2');
    await _until(() => !store.isSending(store.activeId));
  });

  test('old-topic replay does not rotate again', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.quickAgentRotateAfter = 3;
    store.quickAgentRotateTokens = 0;
    store.conversations.clear();

    Future<void> talk(String text, String reply) async {
      final fut = store.send(text: text);
      await _until(() => store.active!.pendingRunId != null);
      api.finish(store.active!.pendingRunId!, reply);
      await fut;
    }

    store.newChat();
    await talk('天气怎么样', '晴');
    final firstTopic = store.active!;
    store.newChat();
    await talk('1+1', '2');
    final secondTopic = store.active!;
    store.newChat();
    await talk('现在几点', '三点');
    final rotated = store.quickAgentId;
    expect(rotated, isNot(firstTopic.agentId));

    store.selectChat(firstTopic.id);
    await talk('明天呢', '也晴');
    expect(store.quickAgentId, rotated);
    expect(api.createdPrompts.last, contains('话题回溯'));

    store.selectChat(secondTopic.id);
    await talk('再加一', '3');
    expect(store.quickAgentId, rotated);
    expect(api.createdPrompts.last, contains('话题回溯'));
    expect(api.createdPrompts.last, contains('1+1'));
    expect(store.active!.agentId, rotated);
  });

  test('quick follow-up ERROR keeps the shared agent', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations.clear();

    Future<void> talk(String text, String reply) async {
      final fut = store.send(text: text);
      await _until(() => store.active!.pendingRunId != null);
      api.finish(store.active!.pendingRunId!, reply);
      await fut;
    }

    store.newChat();
    await talk('天气怎么样', '晴');
    final firstTopic = store.active!;
    final agent = store.quickAgentId;
    store.newChat();
    await talk('1+1', '2');
    expect(store.quickAgentId, agent);

    store.selectChat(firstTopic.id);
    api.failRuns = true;
    final follow = store.send(text: '明天呢');
    await follow;
    expect(store.quickAgentId, agent);
    expect(
      api.createdPrompts.where((p) => p.contains(kFirstTurnPrefix)).length,
      1,
    );
    expect(store.error, isNotNull);
  });

  test('token threshold precreates and rotates on the next new topic', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.quickAgentRotateAfter = 0;
    store.quickAgentRotateTokens = 100;
    store.conversations.clear();

    store.newChat();
    api.usageResponse = const AgentTokenUsage(
      inputTokens: 40,
      cacheReadTokens: 70,
    );
    final first = store.send(text: '很长的上下文');
    await _until(() => store.active!.pendingRunId != null);
    final firstAgent = store.quickAgentId;
    api.finish(store.active!.pendingRunId!, '收到');
    await first;
    await _until(() => store.quickAgentLastInputTokens >= 100);

    store.newChat();
    final second = store.send(text: '新话题');
    await _until(() => store.active!.pendingRunId != null);
    expect(store.quickAgentId, isNot(firstAgent));
    api.finish(store.active!.pendingRunId!, '好');
    await second;
  });
}
