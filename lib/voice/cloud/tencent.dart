import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../voice_settings.dart';
import 'cloud_stt.dart';

Future<String> transcribeTencent({
  required http.Client client,
  required CloudSttSecrets secrets,
  required Uint8List wav,
}) async {
  const host = 'asr.tencentcloudapi.com';
  const action = 'SentenceRecognition';
  const version = '2019-06-14';
  const service = 'asr';
  final now = DateTime.now().toUtc();
  final date = _ymd(now);
  final timestamp = '${now.millisecondsSinceEpoch ~/ 1000}';
  final payload = jsonEncode({
    'EngSerViceType': '16k_zh',
    'SourceType': 1,
    'VoiceFormat': 'wav',
    'Data': base64Encode(wav),
    'DataLen': wav.length,
  });
  final hashedPayload = sha256.convert(utf8.encode(payload)).toString();
  const contentType = 'application/json; charset=utf-8';
  final canonicalHeaders =
      'content-type:$contentType\n'
      'host:$host\n'
      'x-tc-action:${action.toLowerCase()}\n';
  const signedHeaders = 'content-type;host;x-tc-action';
  final canonicalRequest =
      'POST\n/\n\n$canonicalHeaders\n$signedHeaders\n$hashedPayload';
  final hashedCanonical = sha256
      .convert(utf8.encode(canonicalRequest))
      .toString();
  final credentialScope = '$date/$service/tc3_request';
  final stringToSign =
      'TC3-HMAC-SHA256\n$timestamp\n$credentialScope\n$hashedCanonical';
  final secretDate = _hmac(utf8.encode('TC3${secrets.secretKey.trim()}'), date);
  final secretService = _hmac(secretDate, service);
  final secretSigning = _hmac(secretService, 'tc3_request');
  final signature = Hmac(
    sha256,
    secretSigning,
  ).convert(utf8.encode(stringToSign));
  final auth =
      'TC3-HMAC-SHA256 Credential=${secrets.accessKey.trim()}/$credentialScope, '
      'SignedHeaders=$signedHeaders, Signature=$signature';
  final res = await client.post(
    Uri.parse('https://$host'),
    headers: {
      'Authorization': auth,
      'Content-Type': contentType,
      'Host': host,
      'X-TC-Action': action,
      'X-TC-Timestamp': timestamp,
      'X-TC-Version': version,
      'X-TC-Region': 'ap-guangzhou',
    },
    body: payload,
  );
  if (res.statusCode < 200 || res.statusCode >= 300) throwHttp(res);
  final text = readJsonText(res.body, const [
    'Response.Result',
    'Response.FlashResult.0.text',
  ]);
  if (text.isEmpty) {
    throw HttpException('没有识别结果：${res.body}');
  }
  return text;
}

List<int> _hmac(List<int> key, String msg) =>
    Hmac(sha256, key).convert(utf8.encode(msg)).bytes;

String _ymd(DateTime d) {
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year}-$m-$day';
}
