enum VoiceMode { off, system, local, cloud }

VoiceMode voiceModeFromId(String? raw) {
  return switch (raw) {
    'system' => VoiceMode.system,
    'local' => VoiceMode.local,
    'cloud' => VoiceMode.cloud,
    _ => VoiceMode.off,
  };
}

extension VoiceModeX on VoiceMode {
  String get id => name;

  String get label => switch (this) {
    VoiceMode.off => '关闭',
    VoiceMode.system => '系统听写',
    VoiceMode.local => '本地',
    VoiceMode.cloud => '云端（测试）',
  };
}

class CloudSttSecrets {
  const CloudSttSecrets({
    this.apiKey = '',
    this.appId = '',
    this.accessKey = '',
    this.secretKey = '',
  });

  final String apiKey;
  final String appId;
  final String accessKey;
  final String secretKey;

  bool get isEmpty =>
      apiKey.isEmpty && appId.isEmpty && accessKey.isEmpty && secretKey.isEmpty;

  Map<String, String> toJson() => {
    if (apiKey.isNotEmpty) 'apiKey': apiKey,
    if (appId.isNotEmpty) 'appId': appId,
    if (accessKey.isNotEmpty) 'accessKey': accessKey,
    if (secretKey.isNotEmpty) 'secretKey': secretKey,
  };

  factory CloudSttSecrets.fromJson(Map<String, dynamic> json) {
    return CloudSttSecrets(
      apiKey: '${json['apiKey'] ?? ''}',
      appId: '${json['appId'] ?? ''}',
      accessKey: '${json['accessKey'] ?? ''}',
      secretKey: '${json['secretKey'] ?? ''}',
    );
  }

  CloudSttSecrets copyWith({
    String? apiKey,
    String? appId,
    String? accessKey,
    String? secretKey,
  }) {
    return CloudSttSecrets(
      apiKey: apiKey ?? this.apiKey,
      appId: appId ?? this.appId,
      accessKey: accessKey ?? this.accessKey,
      secretKey: secretKey ?? this.secretKey,
    );
  }
}

class CloudSttProviderInfo {
  const CloudSttProviderInfo({
    required this.id,
    required this.label,
    required this.fields,
    required this.hint,
    required this.ready,
  });

  final String id;
  final String label;
  final List<CloudField> fields;
  final String hint;
  final bool Function(CloudSttSecrets s) ready;
}

class CloudField {
  const CloudField(this.key, this.label, {this.obscure = true});

  final String key;
  final String label;
  final bool obscure;
}

const kDefaultLocalSttId = 'sensevoice';
const kDefaultCloudProvider = 'aliyun';

final cloudSttProviders = <CloudSttProviderInfo>[
  CloudSttProviderInfo(
    id: 'aliyun',
    label: '阿里云百炼',
    fields: const [CloudField('apiKey', 'DashScope API Key')],
    hint: '用 Qwen3-ASR-Flash。测试：识别效果未验证。',
    ready: (s) => s.apiKey.trim().isNotEmpty,
  ),
  CloudSttProviderInfo(
    id: 'tencent',
    label: '腾讯云',
    fields: const [
      CloudField('accessKey', 'SecretId'),
      CloudField('secretKey', 'SecretKey'),
    ],
    hint: '一句话识别。测试：识别效果未验证。',
    ready: (s) =>
        s.accessKey.trim().isNotEmpty && s.secretKey.trim().isNotEmpty,
  ),
  CloudSttProviderInfo(
    id: 'baidu',
    label: '百度智能云',
    fields: const [
      CloudField('apiKey', 'API Key'),
      CloudField('secretKey', 'Secret Key'),
    ],
    hint: '短语音识别。测试：识别效果未验证。',
    ready: (s) => s.apiKey.trim().isNotEmpty && s.secretKey.trim().isNotEmpty,
  ),
  CloudSttProviderInfo(
    id: 'xunfei',
    label: '讯飞',
    fields: const [
      CloudField('appId', 'AppID', obscure: false),
      CloudField('apiKey', 'API Key'),
      CloudField('secretKey', 'API Secret'),
    ],
    hint: '听写 HTTP 接口。测试：识别效果未验证。',
    ready: (s) =>
        s.appId.trim().isNotEmpty &&
        s.apiKey.trim().isNotEmpty &&
        s.secretKey.trim().isNotEmpty,
  ),
  CloudSttProviderInfo(
    id: 'volcengine',
    label: '火山引擎',
    fields: const [
      CloudField('appId', 'AppID', obscure: false),
      CloudField('accessKey', 'Access Token'),
    ],
    hint: '大模型录音识别 Flash。测试：识别效果未验证。',
    ready: (s) => s.appId.trim().isNotEmpty && s.accessKey.trim().isNotEmpty,
  ),
  CloudSttProviderInfo(
    id: 'openai',
    label: 'OpenAI Whisper',
    fields: const [CloudField('apiKey', 'API Key')],
    hint: '测试：识别效果未验证。',
    ready: (s) => s.apiKey.trim().isNotEmpty,
  ),
  CloudSttProviderInfo(
    id: 'groq',
    label: 'Groq Whisper',
    fields: const [CloudField('apiKey', 'API Key')],
    hint: '测试：识别效果未验证。',
    ready: (s) => s.apiKey.trim().isNotEmpty,
  ),
];

CloudSttProviderInfo? cloudProviderById(String id) {
  for (final p in cloudSttProviders) {
    if (p.id == id) return p;
  }
  return null;
}

bool cloudSecretsReady(String providerId, CloudSttSecrets secrets) {
  final info = cloudProviderById(providerId);
  return info != null && info.ready(secrets);
}

String secretField(CloudSttSecrets s, String key) {
  return switch (key) {
    'apiKey' => s.apiKey,
    'appId' => s.appId,
    'accessKey' => s.accessKey,
    'secretKey' => s.secretKey,
    _ => '',
  };
}

CloudSttSecrets withSecretField(CloudSttSecrets s, String key, String value) {
  return switch (key) {
    'apiKey' => s.copyWith(apiKey: value),
    'appId' => s.copyWith(appId: value),
    'accessKey' => s.copyWith(accessKey: value),
    'secretKey' => s.copyWith(secretKey: value),
    _ => s,
  };
}
