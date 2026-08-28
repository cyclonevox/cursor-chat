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
}
