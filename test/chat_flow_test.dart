import 'package:cursor_chat/main.dart';
import 'package:cursor_chat/models/models.dart';
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

  test('same chat ignores a second send while loading', () async {
    final api = FakeCursorApi();
    final store = ChatStore(client: api);
    store.apiKey = 'k';
    store.conversations
      ..clear()
      ..add(Conversation(id: 'a', title: '对话A'));
    store.activeId = 'a';

    final first = store.send(text: '牛顿第一定律是什么');
    await _until(() => api.createdPrompts.length == 1);
    await store.send(text: '第二句不该发出去');
    expect(api.createdPrompts, hasLength(1));
    expect(store.active!.messages.where((m) => m.role == 'user'), hasLength(1));

    api.finish('run-1', '牛顿第一定律是指惯性定律。');
    await first;
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
      isFalse,
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
      isFalse,
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

    await tester.tap(find.byTooltip('新对话'));
    await tester.pump();
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
    await tester.tap(
      find
          .descendant(
            of: find.byType(Drawer),
            matching: find.byIcon(Icons.delete_outline),
          )
          .first,
    );
    await tester.pump();
    expect(store.conversations.length, 2);
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
    expect(
      tester.widget<TextField>(find.byKey(const Key('composer-input'))).enabled,
      isFalse,
      reason: '回退到新 agent 时仍应显示载入中',
    );

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

  test(
    'follow-up network drop dumps local session into a new agent',
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
      expect(
        store.active!.messages.where((m) => m.role == 'user'),
        hasLength(2),
      );
    },
  );

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

  test('resumeInFlight recovers a failed bubble that still has a run id', () async {
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
  });

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
}
