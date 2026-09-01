import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'model_catalog.dart';
import 'model_store.dart';
import 'pcm_recorder.dart';
import 'stt_engine.dart';
import 'wav.dart';

var _bindingsReady = false;

void ensureSherpaBindings() {
  if (_bindingsReady) return;
  sherpa.initBindings();
  _bindingsReady = true;
}

class LocalSherpaStt implements SttEngine {
  LocalSherpaStt({
    required this.modelId,
    required this.store,
    PcmRecorder? recorder,
  }) : _recorder = recorder ?? PcmRecorder();

  final String modelId;
  final ModelStore store;
  final PcmRecorder _recorder;

  sherpa.OnlineRecognizer? _online;
  sherpa.OnlineStream? _stream;
  void Function(String partial)? _onPartial;
  LocalSttModel? get _model => localSttById(modelId);

  @override
  bool get streaming => _model?.streaming ?? false;

  @override
  Future<void> start({void Function(String partial)? onPartial}) async {
    _onPartial = onPartial;
    ensureSherpaBindings();
    final model = _model;
    if (model == null) throw StateError('未知本地模型 $modelId');
    if (!await store.refreshReady(modelId)) {
      throw StateError('还没下载完这个模型');
    }
    if (model.streaming) {
      await _openOnline(model);
      _recorder.onChunk = _acceptPcm;
    } else {
      _recorder.onChunk = null;
    }
    await _recorder.start();
  }

  @override
  Future<String> finish() async {
    final pcm = await _recorder.stop();
    _recorder.onChunk = null;
    final model = _model;
    if (model == null) return '';
    if (model.streaming) {
      _flushOnline(pcm16ToFloat32(Uint8List(32000)));
      _stream?.inputFinished();
      _drainOnline();
      final text = _online?.getResult(_stream!).text.trim() ?? '';
      _closeOnline();
      return text;
    }
    if (pcm.isEmpty) return '';
    return _decodeOffline(model, pcm16ToFloat32(pcm));
  }

  @override
  Future<void> cancel() async {
    _recorder.onChunk = null;
    await _recorder.cancel();
    _closeOnline();
  }

  void _acceptPcm(Uint8List chunk) {
    _flushOnline(pcm16ToFloat32(chunk));
    _drainOnline();
    final text = _online?.getResult(_stream!).text ?? '';
    if (text.trim().isNotEmpty) _onPartial?.call(text.trim());
  }

  void _flushOnline(Float32List samples) {
    final stream = _stream;
    if (stream == null || samples.isEmpty) return;
    stream.acceptWaveform(samples: samples, sampleRate: 16000);
  }

  void _drainOnline() {
    final rec = _online;
    final stream = _stream;
    if (rec == null || stream == null) return;
    while (rec.isReady(stream)) {
      rec.decode(stream);
    }
  }

  Future<void> _openOnline(LocalSttModel model) async {
    final tokens = await store.filePath(model.id, 'tokens.txt');
    late final sherpa.OnlineModelConfig cfg;
    if (model.kind == LocalSttKind.zipformerTransducer) {
      cfg = sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: await store.filePath(model.id, 'encoder.int8.onnx'),
          decoder: await store.filePath(model.id, 'decoder.onnx'),
          joiner: await store.filePath(model.id, 'joiner.int8.onnx'),
        ),
        tokens: tokens,
        modelType: 'zipformer2',
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    } else {
      cfg = sherpa.OnlineModelConfig(
        zipformer2Ctc: sherpa.OnlineZipformer2CtcModelConfig(
          model: await store.filePath(model.id, 'model.int8.onnx'),
        ),
        tokens: tokens,
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      );
    }
    _online = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(model: cfg),
    );
    _stream = _online!.createStream();
  }

  void _closeOnline() {
    _stream?.free();
    _online?.free();
    _stream = null;
    _online = null;
  }

  Future<String> _decodeOffline(
    LocalSttModel model,
    Float32List samples,
  ) async {
    final rec = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: await store.filePath(model.id, 'model.int8.onnx'),
            language: 'auto',
            useInverseTextNormalization: true,
          ),
          tokens: await store.filePath(model.id, 'tokens.txt'),
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
      ),
    );
    sherpa.VoiceActivityDetector? vad;
    try {
      final parts = <String>[];
      if (model.needsVad) {
        vad = sherpa.VoiceActivityDetector(
          config: sherpa.VadModelConfig(
            sileroVad: sherpa.SileroVadModelConfig(
              model: await store.filePath(kVadModelId, 'silero_vad.onnx'),
            ),
            sampleRate: 16000,
            numThreads: 1,
            debug: false,
          ),
          bufferSizeInSeconds: 30,
        );
        const window = 512;
        for (var i = 0; i + window <= samples.length; i += window) {
          vad.acceptWaveform(Float32List.sublistView(samples, i, i + window));
          _drainVad(vad, rec, parts);
        }
        vad.flush();
        _drainVad(vad, rec, parts);
      }
      if (parts.isEmpty) {
        parts.add(_decodeSamples(rec, samples));
      }
      return parts.where((t) => t.isNotEmpty).join(' ').trim();
    } finally {
      vad?.free();
      rec.free();
    }
  }

  void _drainVad(
    sherpa.VoiceActivityDetector vad,
    sherpa.OfflineRecognizer rec,
    List<String> parts,
  ) {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      if (seg.samples.isEmpty) continue;
      parts.add(_decodeSamples(rec, seg.samples));
    }
  }

  String _decodeSamples(sherpa.OfflineRecognizer rec, Float32List samples) {
    if (samples.isEmpty) return '';
    final stream = rec.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      rec.decode(stream);
      return rec.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }
}
