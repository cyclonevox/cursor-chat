import 'dart:io';

import 'package:cursor_chat/main.dart';
import 'package:cursor_chat/store.dart';
import 'package:cursor_chat/voice/stt_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeStt implements SttEngine {
  bool cancelled = false;

  @override
  bool get streaming => true;

  @override
  Future<void> start({
    void Function(String partial)? onPartial,
    void Function(double level)? onLevel,
  }) async {
    onPartial?.call('半成品');
  }

  @override
  Future<String> finish() async => '你好世界';

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugSttFactory = null;
  });

  testWidgets('linux window: hidden mic, settings, tick/cancel', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    await tester.binding.setSurfaceSize(const Size(420, 860));
    await tester.pumpWidget(ChatApp(store: store));
    await tester.pump();

    expect(find.byKey(const Key('composer-mic')), findsNothing);
    expect(find.byKey(const Key('composer-send')), findsOneWidget);

    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('语音输入'), findsOneWidget);
    expect(find.byKey(const Key('voice-mode-system')), findsNothing);
    expect(find.textContaining('系统听写只在 Android 上可用'), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice-mode-local')));
    await tester.pump();
    expect(
      find.byKey(const Key('local-stt-sensevoice'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('download-stt-zipformer-small'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(store.voiceMicReady, isFalse);

    await tester.tap(find.byKey(const Key('voice-mode-cloud')));
    await tester.pump();
    final keyField = find.byKey(
      const Key('cloud-field-aliyun-apiKey'),
      skipOffstage: false,
    );
    expect(keyField, findsOneWidget);
    await tester.ensureVisible(keyField);
    await tester.pump();
    await tester.enterText(keyField, 'linux-ui-test-key');
    await tester.pump();
    expect(store.voiceMicReady, isTrue);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('composer-mic')), findsOneWidget);
    final mic = tester.getCenter(find.byKey(const Key('composer-mic')));
    final send = tester.getCenter(find.byKey(const Key('composer-send')));
    expect(mic.dx, lessThan(send.dx));

    final fake = _FakeStt();
    debugSttFactory = () => fake;
    await tester.enterText(find.byKey(const Key('composer-input')), '已有');
    await tester.tap(find.byKey(const Key('composer-mic')));
    await tester.pump();
    expect(find.byKey(const Key('composer-voice-cancel')), findsOneWidget);
    expect(find.byKey(const Key('composer-voice-confirm')), findsOneWidget);
    expect(find.byKey(const Key('composer-voice-meter')), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('composer-input')))
          .controller!
          .text,
      '已有 半成品',
    );

    await tester.tap(find.byKey(const Key('composer-voice-cancel')));
    await tester.pump();
    expect(fake.cancelled, isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('composer-input')))
          .controller!
          .text,
      '已有',
    );

    await tester.tap(find.byKey(const Key('composer-mic')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-voice-confirm')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('composer-input')))
          .controller!
          .text,
      '已有 你好世界',
    );
    expect(store.active!.messages, isEmpty);
    expect(find.byKey(const Key('composer-mic')), findsOneWidget);
    expect(Platform.isLinux, isTrue);
  });
}
