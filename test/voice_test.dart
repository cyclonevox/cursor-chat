import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cursor_chat/main.dart';
import 'package:cursor_chat/store.dart';
import 'package:cursor_chat/voice/cloud/aliyun.dart';
import 'package:cursor_chat/voice/cloud/baidu.dart';
import 'package:cursor_chat/voice/cloud/openai_compat.dart';
import 'package:cursor_chat/voice/cloud/tencent.dart';
import 'package:cursor_chat/voice/cloud/volcengine.dart';
import 'package:cursor_chat/voice/cloud/xunfei.dart';
import 'package:cursor_chat/voice/device_profile.dart';
import 'package:cursor_chat/voice/model_store.dart';
import 'package:cursor_chat/voice/stt_engine.dart';
import 'package:cursor_chat/voice/voice_settings.dart';
import 'package:cursor_chat/voice/wav.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeSttEngine implements SttEngine {
  FakeSttEngine({
    this.partial = '半成品',
    this.finalText = '你好世界',
    this.finishDelay,
  });

  final String partial;
  final String finalText;
  final Duration? finishDelay;
  bool cancelled = false;
  void Function(String partial)? lastPartial;

  @override
  bool get streaming => true;

  @override
  Future<void> start({void Function(String partial)? onPartial}) async {
    lastPartial = onPartial;
    onPartial?.call(partial);
  }

  @override
  Future<String> finish() async {
    if (finishDelay != null) await Future<void>.delayed(finishDelay!);
    return finalText;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

void _mockPathProvider(String path) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        return path;
      });
}

ChatStore _readyCloudStore() {
  final store = ChatStore();
  store.conversations.clear();
  store.newChat();
  store
    ..voiceMode = VoiceMode.cloud
    ..cloudSttProvider = 'aliyun'
    ..cloudSecrets['aliyun'] = const CloudSttSecrets(apiKey: 'test-key');
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugSttFactory = null;
  });

  tearDown(() {
    debugSttFactory = null;
  });

  test('joinTranscript keeps a space between existing text and new words', () {
    expect(joinTranscript('', '你好'), '你好');
    expect(joinTranscript('已有', '新的'), '已有 新的');
    expect(joinTranscript('已有 ', '新的'), '已有 新的');
  });

  test('voiceMicReady stays false until the chosen engine is ready', () {
    final store = ChatStore();
    expect(store.voiceMicReady, isFalse);
    store.voiceMode = VoiceMode.local;
    expect(store.voiceMicReady, isFalse);
    store.voiceMode = VoiceMode.cloud;
    expect(store.voiceMicReady, isFalse);
    store.cloudSecrets['aliyun'] = const CloudSttSecrets(apiKey: 'k');
    expect(store.voiceMicReady, isTrue);
    store.voiceMode = VoiceMode.system;
    expect(store.voiceMicReady, Platform.isAndroid);
    store.voiceMode = VoiceMode.off;
    expect(store.voiceMicReady, isFalse);
  });

  test('linux never treats system dictation as ready', () {
    final store = ChatStore()..voiceMode = VoiceMode.system;
    if (!Platform.isAndroid) {
      expect(store.voiceMicReady, isFalse);
    }
  });

  test('voice settings persist across load', () async {
    final tmp = await Directory.systemTemp.createTemp('voice-prefs');
    addTearDown(() => tmp.delete(recursive: true));
    _mockPathProvider(tmp.path);

    final store = ChatStore();
    store.setVoiceMode(VoiceMode.cloud);
    store.setCloudSttProvider('openai');
    store.setCloudSecret('openai', const CloudSttSecrets(apiKey: 'sk-test'));
    store.setLocalSttId('zipformer-small');
    await store.saveSettings();

    final loaded = ChatStore();
    await loaded.load();
    expect(loaded.voiceMode, VoiceMode.cloud);
    expect(loaded.cloudSttProvider, 'openai');
    expect(loaded.cloudSecret('openai').apiKey, 'sk-test');
    expect(loaded.localSttId, 'zipformer-small');
    expect(loaded.voiceMicReady, isTrue);
  });

  test('recommendLocalModel uses RAM buckets', () async {
    final low = await recommendLocalModel(ramMbOverride: 4096);
    expect(low.id, 'zipformer-small');
    final high = await recommendLocalModel(ramMbOverride: 8192);
    expect(high.id, 'sensevoice');
  });

  test('pcm16 wav header is 44 bytes plus payload', () {
    final pcm = Uint8List.fromList([0, 0, 0, 16]);
    final wav = pcm16ToWav(pcm);
    expect(wav.length, 48);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
  });

  test('model download writes files and marks ready', () async {
    final tmp = await Directory.systemTemp.createTemp('stt-dl');
    addTearDown(() => tmp.delete(recursive: true));
    final bodies = <String, List<int>>{};
    final client = MockClient.streaming((request, body) async {
      final bytes = bodies[request.url.toString()] ?? utf8.encode('x' * 32);
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        200,
        contentLength: bytes.length,
      );
    });
    final store = ModelStore(client: client, documents: () async => tmp);
    store.minBytesOverride = (id, name) => 8;
    await store.download('zipformer-small');
    expect(store.isReady('zipformer-small'), isTrue);
    expect(
      File('${tmp.path}/stt/zipformer-small/tokens.txt').existsSync(),
      isTrue,
    );
  });

  test('model download tries the mirror after the first URL fails', () async {
    final tmp = await Directory.systemTemp.createTemp('stt-mirror');
    addTearDown(() => tmp.delete(recursive: true));
    final hits = <String>[];
    final client = MockClient.streaming((request, body) async {
      hits.add(request.url.host);
      if (request.url.host == 'huggingface.co') {
        return http.StreamedResponse(Stream<List<int>>.value([]), 503);
      }
      final bytes = utf8.encode('ok-file-contents');
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        200,
        contentLength: bytes.length,
      );
    });
    final store = ModelStore(client: client, documents: () async => tmp);
    store.minBytesOverride = (id, name) => 4;
    await store.download('zipformer-small');
    expect(hits.any((h) => h.contains('huggingface')), isTrue);
    expect(hits.any((h) => h.contains('hf-mirror')), isTrue);
    expect(store.isReady('zipformer-small'), isTrue);
  });

  test('paused download is not ready and can retry', () async {
    final tmp = await Directory.systemTemp.createTemp('stt-pause');
    addTearDown(() => tmp.delete(recursive: true));
    final gate = Completer<void>();
    final client = MockClient.streaming((request, body) async {
      await gate.future;
      final bytes = utf8.encode('0123456789');
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        200,
        contentLength: bytes.length,
      );
    });
    final store = ModelStore(client: client, documents: () async => tmp);
    store.minBytesOverride = (id, name) => 4;
    final pending = store.download('zipformer-small');
    await store.cancelDownload('zipformer-small');
    gate.complete();
    await expectLater(pending, throwsA(predicate((e) => '$e'.contains('已暂停'))));
    expect(store.isReady('zipformer-small'), isFalse);
    expect(store.progressFor('zipformer-small')?.error, contains('已暂停'));
  });

  test('cloud adapters parse mocked HTTP bodies', () async {
    final wav = pcm16ToWav(Uint8List(32));
    http.Response jsonOk(Object body) {
      return http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }

    Future<http.Response> reply(http.Request req) async {
      final url = req.url.toString();
      if (url.contains('dashscope')) {
        return jsonOk({
          'choices': [
            {
              'message': {'content': '阿里结果'},
            },
          ],
        });
      }
      if (url.contains('oauth/2.0/token')) {
        return jsonOk({'access_token': 'tok'});
      }
      if (url.contains('vop.baidu.com')) {
        return jsonOk({
          'result': ['百度结果'],
        });
      }
      if (url.contains('asr.tencentcloudapi.com')) {
        return jsonOk({
          'Response': {'Result': '腾讯结果'},
        });
      }
      if (url.contains('xfyun.cn')) {
        return jsonOk({'data': '讯飞结果'});
      }
      if (url.contains('openspeech.bytedance.com')) {
        return jsonOk({
          'result': {'text': '火山结果'},
        });
      }
      if (url.contains('api.openai.com')) {
        return jsonOk({'text': 'OpenAI结果'});
      }
      if (url.contains('api.groq.com')) {
        return jsonOk({'text': 'Groq结果'});
      }
      return http.Response('missing ${req.url}', 404);
    }

    final client = MockClient(reply);
    final secrets = const CloudSttSecrets(
      apiKey: 'k',
      appId: 'app',
      accessKey: 'ak',
      secretKey: 'sk',
    );
    expect(
      await transcribeAliyun(client: client, secrets: secrets, wav: wav),
      '阿里结果',
    );
    expect(
      await transcribeBaidu(client: client, secrets: secrets, wav: wav),
      '百度结果',
    );
    expect(
      await transcribeTencent(client: client, secrets: secrets, wav: wav),
      '腾讯结果',
    );
    expect(
      await transcribeXunfei(client: client, secrets: secrets, wav: wav),
      '讯飞结果',
    );
    expect(
      await transcribeVolcengine(client: client, secrets: secrets, wav: wav),
      '火山结果',
    );
    expect(
      await transcribeOpenAi(client: client, secrets: secrets, wav: wav),
      'OpenAI结果',
    );
    expect(
      await transcribeGroq(client: client, secrets: secrets, wav: wav),
      'Groq结果',
    );
  });

  testWidgets('composer hides the mic until voice is configured', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    await tester.pumpWidget(ChatApp(store: store));
    expect(find.byKey(const Key('composer-mic')), findsNothing);
    expect(find.byKey(const Key('composer-send')), findsOneWidget);
  });

  testWidgets('ready cloud config shows a mic left of send', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = _readyCloudStore();
    await tester.pumpWidget(ChatApp(store: store));
    expect(find.byKey(const Key('composer-mic')), findsOneWidget);
    final mic = tester.getCenter(find.byKey(const Key('composer-mic')));
    final send = tester.getCenter(find.byKey(const Key('composer-send')));
    expect(mic.dx, lessThan(send.dx));
  });

  testWidgets('tick writes the transcript into the input and does not send', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final fake = FakeSttEngine();
    debugSttFactory = () => fake;
    final store = _readyCloudStore();
    await tester.pumpWidget(ChatApp(store: store));
    await tester.enterText(find.byKey(const Key('composer-input')), '已有');
    await tester.tap(find.byKey(const Key('composer-mic')));
    await tester.pump();
    expect(find.byKey(const Key('composer-voice-confirm')), findsOneWidget);
    expect(find.byKey(const Key('composer-voice-cancel')), findsOneWidget);
    expect(find.byKey(const Key('composer-mic')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('composer-input')))
          .controller!
          .text,
      '已有 半成品',
    );

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
  });

  testWidgets('cross restores the text from before listening', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake = FakeSttEngine();
    debugSttFactory = () => fake;
    final store = _readyCloudStore();
    await tester.pumpWidget(ChatApp(store: store));
    await tester.enterText(find.byKey(const Key('composer-input')), '保留');
    await tester.tap(find.byKey(const Key('composer-mic')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('composer-input')))
          .controller!
          .text,
      '保留 半成品',
    );
    await tester.tap(find.byKey(const Key('composer-voice-cancel')));
    await tester.pump();
    expect(fake.cancelled, isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('composer-input')))
          .controller!
          .text,
      '保留',
    );
    expect(store.active!.messages, isEmpty);
  });

  testWidgets('settings voice group can select cloud and store the key', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = ChatStore();
    store.conversations.clear();
    store.newChat();
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: SettingsPage(store: store)));
    await tester.pump();
    expect(find.byKey(const Key('voice-mode-off')), findsOneWidget);
    expect(find.byKey(const Key('voice-mode-system')), findsNothing);
    expect(find.textContaining('系统听写只在 Android 上可用'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-mode-cloud')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('cloud-field-aliyun-apiKey')),
      'sk-live',
    );
    await tester.pump();
    expect(store.voiceMode, VoiceMode.cloud);
    expect(store.cloudSecret('aliyun').apiKey, 'sk-live');
    expect(store.voiceMicReady, isTrue);
  });
}
