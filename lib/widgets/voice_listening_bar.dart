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
      height: 40,
      child: Row(
        children: [
          Expanded(
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
          const SizedBox(width: 10),
          Text(
            formatVoiceElapsed(elapsed),
            key: const Key('composer-voice-elapsed'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: scheme.onSurfaceVariant,
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
    final n = math.max(levels.length, 1);
    final gap = 2.0;
    final barW = math.max(1.5, (size.width - gap * (n - 1)) / n);
    final mid = size.height / 2;
    final paint = Paint()
      ..color = color.withValues(alpha: muted ? 0.35 : 0.82)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barW.clamp(1.5, 3.2);
    for (var i = 0; i < n; i++) {
      final sample = i < levels.length ? levels[i] : 0;
      // Tiny idle ripple so the bar does not look frozen; real RMS drives height.
      final idle = 0.045 + 0.02 * math.sin(phase + i * 0.38);
      final v = sample > 0.05 ? sample : idle;
      final h = (3.0 + v * (size.height - 6)).clamp(3.0, size.height);
      final x = i * (barW + gap) + barW / 2;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.phase != phase ||
      old.muted != muted ||
      old.color != color ||
      old.levels != levels;
}
