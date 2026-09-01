import 'dart:async';
import 'dart:io';

import 'package:speech_to_text/speech_to_text.dart';

import 'stt_engine.dart';

class SystemSttEngine implements SttEngine {
  SystemSttEngine({SpeechToText? speech}) : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  void Function(String partial)? _onPartial;
  String _text = '';
  bool _started = false;

  @override
  bool get streaming => true;

  @override
  Future<void> start({void Function(String partial)? onPartial}) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('系统听写只在 Android 上可用');
    }
    _onPartial = onPartial;
    _text = '';
    final ok = await _speech.initialize(
      onError: (e) {
        _text = _text;
      },
    );
    if (!ok) {
      throw StateError('系统听写不可用。请检查系统语音识别是否已安装。');
    }
    _started = true;
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        localeId: 'zh_CN',
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
      ),
      onResult: (r) {
        _text = r.recognizedWords;
        _onPartial?.call(_text);
      },
    );
  }

  @override
  Future<String> finish() async {
    if (_started) {
      await _speech.stop();
      _started = false;
    }
    return _text.trim();
  }

  @override
  Future<void> cancel() async {
    if (_started) {
      await _speech.cancel();
      _started = false;
    }
    _text = '';
  }
}
