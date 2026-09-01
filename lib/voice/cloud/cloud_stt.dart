import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../pcm_recorder.dart';
import '../stt_engine.dart';
import '../voice_settings.dart';
import '../wav.dart';
import 'aliyun.dart';
import 'baidu.dart';
import 'openai_compat.dart';
import 'tencent.dart';
import 'volcengine.dart';
import 'xunfei.dart';

typedef CloudTranscribe =
    Future<String> Function({
      required http.Client client,
      required CloudSttSecrets secrets,
      required Uint8List wav,
    });

final Map<String, CloudTranscribe> cloudTranscribers = {
  'aliyun': transcribeAliyun,
  'tencent': transcribeTencent,
  'baidu': transcribeBaidu,
  'xunfei': transcribeXunfei,
  'volcengine': transcribeVolcengine,
  'openai': transcribeOpenAi,
  'groq': transcribeGroq,
};

class CloudSttEngine implements SttEngine {
  CloudSttEngine({
    required this.providerId,
    required this.secrets,
    http.Client? client,
    PcmRecorder? recorder,
    this.transcribe,
  }) : _client = client ?? http.Client(),
       _recorder = recorder ?? PcmRecorder();

  final String providerId;
  final CloudSttSecrets secrets;
  final http.Client _client;
  final PcmRecorder _recorder;
  final CloudTranscribe? transcribe;

  @override
  bool get streaming => false;

  @override
  Future<void> start({void Function(String partial)? onPartial}) {
    return _recorder.start();
  }

  @override
  Future<String> finish() async {
    final pcm = await _recorder.stop();
    if (pcm.isEmpty) return '';
    final wav = pcm16ToWav(pcm);
    final fn = transcribe ?? cloudTranscribers[providerId];
    if (fn == null) {
      throw StateError('未知云端服务商 $providerId');
    }
    if (!cloudSecretsReady(providerId, secrets)) {
      throw StateError('还没有填这个服务商的 Key');
    }
    return fn(client: _client, secrets: secrets, wav: wav);
  }

  @override
  Future<void> cancel() => _recorder.cancel();
}

String readJsonText(String body, List<String> paths) {
  try {
    final decoded = jsonDecode(body);
    for (final path in paths) {
      final v = _walk(decoded, path.split('.'));
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
  } catch (_) {}
  return '';
}

dynamic _walk(dynamic node, List<String> parts) {
  var cur = node;
  for (final p in parts) {
    if (cur is Map) {
      cur = cur[p];
    } else if (cur is List && int.tryParse(p) != null) {
      final i = int.parse(p);
      if (i < 0 || i >= cur.length) return null;
      cur = cur[i];
    } else {
      return null;
    }
  }
  return cur;
}

Never throwHttp(http.Response res) {
  throw HttpException('HTTP ${res.statusCode}: ${res.body}');
}

class HttpException implements Exception {
  HttpException(this.message);
  final String message;
  @override
  String toString() => message;
}
