import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'chat/chat_home.dart';
import 'debug/drive_extension.dart';
import 'debug/voice_probe.dart';
import 'store.dart';
import 'theme.dart';
import 'voice/voice_settings.dart';

export 'chat/message_list.dart' show debugChatImagePlaceholder;
export 'settings/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final store = ChatStore();
  await store.load();
  assert(() {
    registerChatDrive(store);
    return true;
  }());
  if (kVoiceUiProbe) {
    if (Platform.isAndroid) {
      store.voiceMode = VoiceMode.system;
    } else {
      store.voiceMode = VoiceMode.cloud;
      store.cloudSttProvider = 'aliyun';
      store.cloudSecrets['aliyun'] = const CloudSttSecrets(apiKey: 'probe');
    }
  }
  runApp(ChatApp(store: store));
}

class ChatApp extends StatefulWidget {
  const ChatApp({super.key, required this.store});

  final ChatStore store;

  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.store.resumeInFlight());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cursor Chat',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      home: ChatHome(store: widget.store),
    );
  }
}
