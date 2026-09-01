import 'cloud/cloud_stt.dart';
import 'local_sherpa_stt.dart';
import 'model_store.dart';
import 'stt_engine.dart';
import 'system_stt.dart';
import 'voice_settings.dart';

abstract class VoiceStoreView {
  VoiceMode get voiceMode;
  String get localSttId;
  String get cloudSttProvider;
  CloudSttSecrets cloudSecret(String providerId);
  ModelStore get modelStore;
}

SttEngine createSttEngine(VoiceStoreView store) {
  if (debugSttFactory != null) return debugSttFactory!();
  switch (store.voiceMode) {
    case VoiceMode.off:
      throw StateError('还没有打开语音输入');
    case VoiceMode.system:
      return SystemSttEngine();
    case VoiceMode.local:
      return LocalSherpaStt(modelId: store.localSttId, store: store.modelStore);
    case VoiceMode.cloud:
      return CloudSttEngine(
        providerId: store.cloudSttProvider,
        secrets: store.cloudSecret(store.cloudSttProvider),
      );
  }
}
