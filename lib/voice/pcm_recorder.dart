import 'dart:async';
import 'dart:typed_data';

import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

class PcmRecorder {
  PcmRecorder({AudioRecorder? recorder, this.requestPermission})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  final Future<bool> Function()? requestPermission;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  StreamSubscription<List<int>>? _sub;
  void Function(Uint8List chunk)? onChunk;

  Future<void> start() async {
    _buf.clear();
    final ok = requestPermission != null
        ? await requestPermission!()
        : await _ensureMic();
    if (!ok) {
      throw StateError('没有麦克风权限');
    }
    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    );
    final stream = await _recorder.startStream(config);
    _sub = stream.listen((data) {
      final bytes = Uint8List.fromList(data);
      _buf.add(bytes);
      onChunk?.call(bytes);
    });
  }

  Future<Uint8List> stop() async {
    await _sub?.cancel();
    _sub = null;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    return _buf.toBytes();
  }

  Future<void> cancel() async {
    await stop();
    _buf.clear();
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _recorder.dispose();
  }

  Future<bool> _ensureMic() async {
    try {
      if (await _recorder.hasPermission()) return true;
    } catch (_) {}
    try {
      final status = await Permission.microphone.request();
      if (status.isGranted) return true;
    } catch (_) {}
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return true;
    }
  }
}
