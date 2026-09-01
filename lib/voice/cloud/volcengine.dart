import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../voice_settings.dart';
import 'cloud_stt.dart';

Future<String> transcribeVolcengine({
  required http.Client client,
  required CloudSttSecrets secrets,
  required Uint8List wav,
}) async {
  final res = await client.post(
    Uri.parse(
      'https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash',
    ),
    headers: {
      'X-Api-App-Key': secrets.appId.trim(),
      'X-Api-Access-Key': secrets.accessKey.trim(),
      'X-Api-Resource-Id': 'volc.bigasr.auc_turbo',
      'X-Api-Request-Id': const Uuid().v4(),
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'user': {'uid': 'cursor-chat'},
      'audio': {'data': base64Encode(wav), 'format': 'wav', 'rate': 16000},
      'request': {'model_name': 'bigmodel'},
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) throwHttp(res);
  final text = readJsonText(res.body, const [
    'result.text',
    'audio_info.text',
    'message',
  ]);
  if (text.isEmpty) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['result'] is Map) {
        final utts = decoded['result']['utterances'];
        if (utts is List && utts.isNotEmpty) {
          return utts.map((u) => '${u['text'] ?? ''}').join().trim();
        }
      }
    } catch (_) {}
    throw HttpException('没有识别结果：${res.body}');
  }
  return text;
}
