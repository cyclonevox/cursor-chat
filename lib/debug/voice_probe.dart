/// `flutter run --dart-define=VOICE_UI_PROBE=true` enables a throwaway
/// in-memory voice config and starts listening once, so the meter can be
/// screenshotted without writing settings.
const kVoiceUiProbe = bool.fromEnvironment('VOICE_UI_PROBE');
