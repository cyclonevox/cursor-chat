import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../voice_settings.dart';
import 'cloud_stt.dart';

Future<String> transcribeBaidu({
  required http.Client client,
  required CloudSttSecrets secrets,
  required Uint8List wav,
}) async {
  final tokenRes = await client.post(
    Uri.parse('https://aip.baidubce.com/oauth/2.0/token').replace(
      queryParameters: {
        'grant_type': 'client_credentials',
        'client_id': secrets.apiKey.trim(),
        'client_secret': secrets.secretKey.trim(),
      },
    ),
  );
  if (tokenRes.statusCode < 200 || tokenRes.statusCode >= 300) {
    throwHttp(tokenRes);
  }
  final token = readJsonText(tokenRes.body, const ['access_token']);
  if (token.isEmpty) {
    throw HttpException('百度 token 失败：${tokenRes.body}');
  }
  final res = await client.post(
    Uri.parse('https://vop.baidu.com/server_api'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'format': 'wav',
      'rate': 16000,
      'channel': 1,
      'cuid': 'cursor-chat',
      'token': token,
      'len': wav.length,
      'speech': base64Encode(wav),
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) throwHttp(res);
  try {
    final decoded = jsonDecode(res.body);
    if (decoded is Map &&
        decoded['result'] is List &&
        decoded['result'].isNotEmpty) {
      return '${decoded['result'][0]}'.trim();
    }
  } catch (_) {}
  throw HttpException('没有识别结果：${res.body}');
}
