import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../voice_settings.dart';
import 'cloud_stt.dart';

Future<String> transcribeXunfei({
  required http.Client client,
  required CloudSttSecrets secrets,
  required Uint8List wav,
}) async {
  final curTime = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
  final param = base64Encode(
    utf8.encode(jsonEncode({'engine_type': 'sms16k', 'aue': 'raw'})),
  );
  final checksum = md5
      .convert(utf8.encode('${secrets.apiKey.trim()}$curTime$param'))
      .toString();
  final res = await client.post(
    Uri.parse('https://api.xfyun.cn/v1/service/v1/iat'),
    headers: {
      'X-Appid': secrets.appId.trim(),
      'X-CurTime': curTime,
      'X-Param': param,
      'X-CheckSum': checksum,
      'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
    },
    body: 'audio=${Uri.encodeQueryComponent(base64Encode(wav))}',
  );
  if (res.statusCode < 200 || res.statusCode >= 300) throwHttp(res);
  final text = readJsonText(res.body, const ['data']);
  if (text.isEmpty) {
    throw HttpException('没有识别结果：${res.body}');
  }
  return text;
}
