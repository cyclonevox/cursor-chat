import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

double pcm16Rms(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  if (n <= 0) return 0;
  final bd = ByteData.sublistView(bytes);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
    sum += v * v;
  }
  return math.sqrt(sum / n).clamp(0.0, 1.0);
}

/// Peak-weighted meter so spoken syllables move the bars more than RMS alone.
double pcm16Vu(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  if (n <= 0) return 0;
  final bd = ByteData.sublistView(bytes);
  var sum = 0.0;
  var peak = 0.0;
  for (var i = 0; i < n; i++) {
    final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
    final a = v.abs();
    if (a > peak) peak = a;
    sum += v * v;
  }
  final rms = math.sqrt(sum / n);
  return (rms * 0.35 + peak * 0.8).clamp(0.0, 1.0);
}

/// Lift typical speech (0.02–0.2) into a visible 0–1 bar height.
double boostVoiceMeter(double level) {
  final x = level.clamp(0.0, 1.0);
  return (math.sqrt(x) * 1.65).clamp(0.0, 1.0);
}

/// True when the buffer is too short or too quiet to be real speech.
bool pcmLooksSilent(Uint8List pcm, {double threshold = 0.004}) {
  // 16 kHz mono s16le: 3200 bytes is 0.1s.
  if (pcm.length < 3200) return true;
  return pcm16Rms(pcm) < threshold;
}

class PcmRecorder {
  PcmRecorder({AudioRecorder? recorder, this.requestPermission})
    : _injected = recorder,
      _recorder = recorder;

  final AudioRecorder? _injected;
  final Future<bool> Function()? requestPermission;
  AudioRecorder? _recorder;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  StreamSubscription<List<int>>? _sub;
  void Function(Uint8List chunk)? onChunk;
  void Function(double level)? onLevel;

  Future<void> start() async {
    await _release();
    _buf.clear();
    final recorder = _injected ?? AudioRecorder();
    _recorder = recorder;
    final ok = requestPermission != null
        ? await requestPermission!()
        : await _ensureMic(recorder);
    if (!ok) {
      await _release();
      throw StateError('没有麦克风权限');
    }
    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    );
    try {
      final stream = await recorder.startStream(config);
      _sub = stream.listen(
        (data) {
          final bytes = Uint8List.fromList(data);
          _buf.add(bytes);
          onChunk?.call(bytes);
          onLevel?.call(pcm16Vu(bytes));
        },
        onError: (_) {},
      );
    } catch (e) {
      await _release();
      throw StateError('打不开麦克风：$e');
    }
  }

  Future<Uint8List> stop() async {
    await _sub?.cancel();
    _sub = null;
    final rec = _recorder;
    if (rec != null) {
      try {
        await rec.stop();
      } catch (_) {}
    }
    final bytes = _buf.toBytes();
    await _release();
    return bytes;
  }

  Future<void> cancel() async {
    await stop();
    _buf.clear();
  }

  Future<void> dispose() => _release();

  Future<void> _release() async {
    await _sub?.cancel();
    _sub = null;
    final rec = _recorder;
    _recorder = _injected;
    if (rec == null) return;
    try {
      if (await rec.isRecording()) await rec.stop();
    } catch (_) {}
    if (!identical(rec, _injected)) {
      try {
        await rec.dispose();
      } catch (_) {}
    }
  }

  Future<bool> _ensureMic(AudioRecorder rec) async {
    try {
      if (await rec.hasPermission()) return true;
    } catch (_) {}
    try {
      final status = await Permission.microphone.request();
      if (status.isGranted) return true;
    } catch (_) {}
    try {
      return await rec.hasPermission();
    } catch (_) {
      return true;
    }
  }
}
