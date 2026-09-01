import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../voice_settings.dart';
import 'cloud_stt.dart';

Future<String> transcribeAliyun({
  required http.Client client,
  required CloudSttSecrets secrets,
  required Uint8List wav,
}) async {
  final b64 = base64Encode(wav);
  final res = await client.post(
    Uri.parse(
      'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    ),
    headers: {
      'Authorization': 'Bearer ${secrets.apiKey.trim()}',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'model': 'qwen3-asr-flash',
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'input_audio',
              'input_audio': {'data': 'data:audio/wav;base64,$b64'},
            },
          ],
        },
      ],
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) throwHttp(res);
  final text = readJsonText(res.body, const [
    'choices.0.message.content',
    'output.choices.0.message.content',
    'output.text',
  ]);
  if (text.isEmpty) {
    throw HttpException('没有识别结果：${res.body}');
  }
  return text;
}
