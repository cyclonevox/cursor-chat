import 'dart:io';

import 'package:cursor_chat/api/cursor_api.dart';
import 'package:cursor_chat/main.dart';
import 'package:cursor_chat/models/models.dart';
import 'package:cursor_chat/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows empty chat and settings entry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    await tester.pumpWidget(ChatApp(store: store));
    expect(find.textContaining('有问题就问'), findsOneWidget);
    expect(find.textContaining('API Key'), findsOneWidget);
  });

  testWidgets('thinking stays collapsed until opened', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    store.active!.title = '这题先通分';
    store.active!.messages.addAll([
      ChatMessage(id: 'u1', role: 'user', text: '这题为啥要先通分？'),
      ChatMessage(
        id: 'a1',
        role: 'assistant',
        text: '因为要先对齐分母。',
        thinking: '先看分数通分的步骤，不要写进正文。',
      ),
    ]);
    await tester.pumpWidget(ChatApp(store: store));
    expect(find.text('这题先通分'), findsWidgets);
    expect(find.text('因为要先对齐分母。'), findsOneWidget);
    expect(find.textContaining('思考过程'), findsOneWidget);
    expect(find.text('先看分数通分的步骤，不要写进正文。'), findsNothing);

    await tester.tap(find.textContaining('思考过程'));
    await tester.pumpAndSettle();
    expect(find.text('先看分数通分的步骤，不要写进正文。'), findsOneWidget);
  });

  testWidgets('assistant reply can be copied', (tester) async {
    SharedPreferences.setMockInitialValues({});
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
          return null;
        }
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': copied};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    store.active!.messages.addAll([
      ChatMessage(id: 'u1', role: 'user', text: '这题为啥要先通分？'),
      ChatMessage(id: 'a1', role: 'assistant', text: '因为要先对齐分母。'),
    ]);
    await tester.pumpWidget(ChatApp(store: store));
    expect(find.byTooltip('复制'), findsOneWidget);

    await tester.tap(find.byTooltip('复制'));
    await tester.pump();
    expect(copied, '因为要先对齐分母。');
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('error banner can be dismissed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    store.error = 'Cursor API 409: stream_unavailable';
    await tester.pumpWidget(ChatApp(store: store));
    expect(find.textContaining('stream_unavailable'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.textContaining('stream_unavailable'), findsNothing);
  });

  testWidgets('opening a chat lands on the latest user message', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    List<ChatMessage> thread(String tag) => [
      for (var i = 0; i < 12; i++) ...[
        ChatMessage(id: '$tag-u$i', role: 'user', text: '$tag 问题$i'),
        ChatMessage(
          id: '$tag-a$i',
          role: 'assistant',
          text: '$tag 回答$i\n${'这段话用来把更早的消息顶出屏幕。' * 6}',
        ),
      ],
    ];

    final store = ChatStore();
    store.conversations
      ..clear()
      ..addAll([
        Conversation(
          id: 'a',
          title: '对话A',
          titleFrozen: true,
          messages: thread('A'),
        ),
        Conversation(
          id: 'b',
          title: '对话B',
          titleFrozen: true,
          messages: thread('B'),
        ),
      ]);
    store.activeId = 'a';

    await tester.pumpWidget(ChatApp(store: store));
    await tester.pumpAndSettle();

    expect(find.text('A 问题11'), findsOneWidget);
    expect(find.textContaining('A 回答11'), findsOneWidget);
    expect(find.text('A 问题0'), findsNothing);
    final latestA = tester.getRect(find.text('A 问题11'));
    expect(latestA.top, greaterThan(kToolbarHeight));
    expect(latestA.bottom, lessThan(720));

    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('对话B'));
    await tester.pumpAndSettle();

    expect(find.text('B 问题11'), findsOneWidget);
    expect(find.text('B 问题0'), findsNothing);
    expect(find.text('A 问题11'), findsNothing);
    final latestB = tester.getRect(find.text('B 问题11'));
    expect(latestB.top, greaterThan(kToolbarHeight));
    expect(latestB.bottom, lessThan(720));
  });

  testWidgets('short chat keeps the latest turn above the composer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    store.active!.title = '短对话';
    store.active!.messages.addAll([
      ChatMessage(id: 'u1', role: 'user', text: '1+1等于几？'),
      ChatMessage(id: 'a1', role: 'assistant', text: '2'),
    ]);

    await tester.pumpWidget(ChatApp(store: store));
    await tester.pumpAndSettle();

    final user = tester.getRect(find.text('1+1等于几？'));
    final reply = tester.getRect(find.text('2'));
    expect(user.top, greaterThan(400));
    expect(reply.top, greaterThan(user.bottom));
    expect(reply.bottom, lessThan(800 - 80));
  });

  testWidgets('settings explains how to get an API key', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    await tester.pumpWidget(ChatApp(store: store));
    expect(find.textContaining('打开设置'), findsOneWidget);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('怎么拿到 Key'), findsOneWidget);
    expect(find.text(kCursorApiKeyUrl), findsOneWidget);
    expect(find.text('保存并刷新模型'), findsOneWidget);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
          return null;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.tap(find.byKey(const Key('copy-api-key-url')));
    await tester.pump();
    expect(copied, kCursorApiKeyUrl);
    expect(find.text('网址已复制，去浏览器打开'), findsOneWidget);
  });

  testWidgets('tapping a sent image opens a viewer', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugChatImagePlaceholder = true;
    addTearDown(() => debugChatImagePlaceholder = false);

    final path = File('assets/icon.png').absolute.path;
    expect(File(path).existsSync(), isTrue);

    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    store.active!.messages.add(
      ChatMessage(id: 'u1', role: 'user', text: '看这题', imagePaths: [path]),
    );

    await tester.pumpWidget(ChatApp(store: store));
    await tester.pump();
    await tester.tap(find.byKey(Key('chat-image-$path')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.text('看这题'), findsOneWidget);
  });
}
