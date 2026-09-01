import 'dart:math' as math;

import 'package:flutter/material.dart';

String formatVoiceElapsed(Duration elapsed) {
  final s = elapsed.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class VoiceListeningBar extends StatelessWidget {
  const VoiceListeningBar({
    super.key,
    required this.levels,
    required this.elapsed,
    this.phase = 0,
    this.transcribing = false,
  });

  final List<double> levels;
  final Duration elapsed;
  final double phase;
  final bool transcribing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ClipRect(
                child: CustomPaint(
                  painter: _WavePainter(
                    levels: levels,
                    color: scheme.onSurface,
                    phase: phase,
                    muted: transcribing,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 42,
            child: Text(
              formatVoiceElapsed(elapsed),
              key: const Key('composer-voice-elapsed'),
              textAlign: TextAlign.right,
              maxLines: 1,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.levels,
    required this.color,
    required this.phase,
    required this.muted,
  });

  final List<double> levels;
  final Color color;
  final double phase;
  final bool muted;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final n = math.max(levels.length, 1);
    final gap = 3.0;
    final barW = math.max(2.5, (size.width - gap * (n - 1)) / n);
    final stroke = barW.clamp(2.5, 4.0);
    final usable = size.width - stroke;
    final step = n == 1 ? 0.0 : usable / (n - 1);
    final mid = size.height / 2;
    final paint = Paint()
      ..color = color.withValues(alpha: muted ? 0.35 : 0.9)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    for (var i = 0; i < n; i++) {
      final sample = i < levels.length ? levels[i] : 0.0;
      final idle = 0.22 + 0.16 * math.sin(phase + i * 0.42);
      final v = math.max(sample, idle);
      final h = (6.0 + v * (size.height - 10)).clamp(6.0, size.height - 2);
      final x = stroke / 2 + i * step;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.phase != phase ||
      old.muted != muted ||
      old.color != color ||
      old.levels != levels;
}
