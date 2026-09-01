import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../voice_settings.dart';
import 'cloud_stt.dart';

Future<String> transcribeOpenAi({
  required http.Client client,
  required CloudSttSecrets secrets,
  required Uint8List wav,
}) {
  return _openaiWhisper(
    client: client,
    url: 'https://api.openai.com/v1/audio/transcriptions',
    apiKey: secrets.apiKey,
    model: 'whisper-1',
    wav: wav,
  );
}

Future<String> transcribeGroq({
  required http.Client client,
  required CloudSttSecrets secrets,
  required Uint8List wav,
}) {
  return _openaiWhisper(
    client: client,
    url: 'https://api.groq.com/openai/v1/audio/transcriptions',
    apiKey: secrets.apiKey,
    model: 'whisper-large-v3',
    wav: wav,
  );
}

Future<String> _openaiWhisper({
  required http.Client client,
  required String url,
  required String apiKey,
  required String model,
  required Uint8List wav,
}) async {
  final req = http.MultipartRequest('POST', Uri.parse(url))
    ..headers['Authorization'] = 'Bearer ${apiKey.trim()}'
    ..fields['model'] = model
    ..fields['language'] = 'zh'
    ..files.add(
      http.MultipartFile.fromBytes(
        'file',
        wav,
        filename: 'audio.wav',
        contentType: MediaType('audio', 'wav'),
      ),
    );
  final streamed = await client.send(req);
  final res = await http.Response.fromStream(streamed);
  if (res.statusCode < 200 || res.statusCode >= 300) throwHttp(res);
  final text = readJsonText(res.body, const ['text']);
  if (text.isEmpty) {
    throw HttpException('没有识别结果：${res.body}');
  }
  return text;
}
