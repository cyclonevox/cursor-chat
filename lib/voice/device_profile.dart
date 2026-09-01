import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import 'model_catalog.dart';

class SttRecommendation {
  const SttRecommendation({required this.id, required this.reason});

  final String id;
  final String reason;
}

Future<SttRecommendation> recommendLocalModel({
  DeviceInfoPlugin? plugin,
  int? ramMbOverride,
}) async {
  if (ramMbOverride != null) {
    return _fromRam(ramMbOverride);
  }
  if (!Platform.isAndroid) {
    return const SttRecommendation(
      id: 'sensevoice',
      reason: '建议在手机上用本地识别。这台设备也可以下模型试链路。',
    );
  }
  try {
    final info = await (plugin ?? DeviceInfoPlugin()).androidInfo;
    final ram = info.physicalRamSize;
    if (ram > 0) return _fromRam(ram);
  } catch (_) {}
  return const SttRecommendation(
    id: 'sensevoice',
    reason: '默认建议更准档（SenseVoice）。',
  );
}

SttRecommendation _fromRam(int ramMb) {
  if (ramMb < 5000) {
    return SttRecommendation(
      id: 'zipformer-small',
      reason: '这台机内存约 ${ramMb}MB，建议省资源档。',
    );
  }
  return SttRecommendation(
    id: 'sensevoice',
    reason: '这台机内存约 ${ramMb}MB，建议更准档。也可以选更跟手。',
  );
}

String recommendationBadge(String modelId, String recommendedId) {
  if (modelId != recommendedId) return '';
  final m = localSttById(modelId);
  return m == null ? '建议' : '本机建议';
}
