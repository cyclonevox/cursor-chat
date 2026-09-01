abstract class SttEngine {
  bool get streaming;

  Future<void> start({
    void Function(String partial)? onPartial,
    void Function(double level)? onLevel,
  });

  Future<String> finish();

  Future<void> cancel();
}

/// Widget tests inject a fake engine so Composer never opens the mic.
SttEngine Function()? debugSttFactory;

String joinTranscript(String existing, String incoming) {
  final a = existing;
  final b = incoming.trim();
  if (b.isEmpty) return a;
  if (a.isEmpty) return b;
  if (a.endsWith(' ') || a.endsWith('\n') || a.endsWith('　')) {
    return '$a$b';
  }
  return '$a $b';
}
