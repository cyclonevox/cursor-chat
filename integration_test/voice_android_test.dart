import 'dart:io';

import 'package:cursor_chat/main.dart';
import 'package:cursor_chat/store.dart';
import 'package:cursor_chat/voice/model_store.dart';
import 'package:cursor_chat/voice/stt_engine.dart';
import 'package:cursor_chat/voice/system_stt.dart';
import 'package:cursor_chat/voice/voice_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugSttFactory = null;
    debugRewriteDownloadUrl = null;
  });

  testWidgets('android emulator: system listen, local download, local start', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    debugRewriteDownloadUrl = _rewriteToHostServer;
    SharedPreferences.setMockInitialValues({});
    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    await tester.binding.setSurfaceSize(const Size(400, 840));
    await tester.pumpWidget(ChatApp(store: store));
    await tester.pump();
    expect(find.byKey(const Key('composer-mic')), findsNothing);

    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('voice-mode-system')), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-mode-system')));
    await tester.pump();
    expect(store.voiceMode, VoiceMode.system);
    expect(store.voiceMicReady, isTrue);
    expect(createSystemEngine(), isA<SystemSttEngine>());

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('composer-mic')), findsOneWidget);

    await tester.tap(find.byKey(const Key('composer-mic')));
    await _waitForVoiceConfirm(tester);
    await tester.tap(find.byKey(const Key('composer-voice-cancel')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('composer-mic')), findsOneWidget);

    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('voice-mode-local')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    for (final id in ['sensevoice', 'zipformer-large', 'zipformer-small']) {
      await tester.scrollUntilVisible(
        find.byKey(Key('local-stt-$id'), skipOffstage: false),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(
        find.byKey(Key('download-stt-$id'), skipOffstage: false),
        findsOneWidget,
      );
    }

    await tester.tap(find.byKey(const Key('download-stt-zipformer-small')));
    var ready = false;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (await store.modelStore.refreshReady('zipformer-small')) {
        ready = true;
        break;
      }
      final err = store.modelStore.progressFor('zipformer-small')?.error;
      if (err != null) {
        fail('zipformer-small 下载失败: $err');
      }
    }
    expect(ready, isTrue, reason: 'zipformer-small 没有在超时内下完');
    await tester.pump();

    await tester.scrollUntilVisible(
      find.byKey(const Key('select-stt-zipformer-small'), skipOffstage: false),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(
      find.byKey(const Key('select-stt-zipformer-small'), skipOffstage: false),
    );
    await tester.pump();
    expect(store.localSttId, 'zipformer-small');
    expect(store.voiceMicReady, isTrue);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('composer-mic')), findsOneWidget);
    await tester.tap(find.byKey(const Key('composer-mic')));
    await _waitForVoiceConfirm(tester);
    await tester.tap(find.byKey(const Key('composer-voice-cancel')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('composer-mic')), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 8)));
}

String _rewriteToHostServer(String url) {
  final name = Uri.parse(url).pathSegments.last;
  if (name == 'silero_vad.onnx') {
    return 'http://127.0.0.1:8765/silero-vad/silero_vad.onnx';
  }
  if (url.contains('small-ctc')) {
    return 'http://127.0.0.1:8765/zipformer-small/$name';
  }
  if (url.contains('2025-06-30')) {
    return 'http://127.0.0.1:8765/zipformer-large/$name';
  }
  if (url.contains('sense-voice')) {
    return 'http://127.0.0.1:8765/sensevoice/$name';
  }
  return url;
}

Future<void> _waitForVoiceConfirm(WidgetTester tester) async {
  var sawConfirm = false;
  Finder? snack;
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (find.byKey(const Key('composer-voice-confirm')).evaluate().isNotEmpty) {
      sawConfirm = true;
      break;
    }
    snack = find.byType(SnackBar);
    if (snack.evaluate().isNotEmpty) break;
  }
  expect(
    sawConfirm,
    isTrue,
    reason: () {
      if (snack != null && snack.evaluate().isNotEmpty) {
        final content = tester.widget<SnackBar>(snack).content;
        if (content is Text) return content.data ?? content.toString();
        return content.toString();
      }
      return '听写没有进入进行中状态（未出现完成按钮，也没有 SnackBar）';
    }(),
  );
}

SttEngine createSystemEngine() => SystemSttEngine();
