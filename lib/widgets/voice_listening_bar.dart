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
    this.transcribing = false,
  });

  final List<double> levels;
  final Duration elapsed;
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
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: ClipRect(
                child: CustomPaint(
                  painter: _WavePainter(
                    levels: levels,
                    color: scheme.onSurface,
                    muted: transcribing,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 44,
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
    required this.muted,
  });

  final List<double> levels;
  final Color color;
  final bool muted;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final n = math.max(levels.length, 1);
    const stroke = 1.6;
    const fade = 0.14;
    final usable = math.max(size.width - stroke, 0.0);
    final step = n == 1 ? 0.0 : usable / (n - 1);
    final mid = size.height / 2;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    for (var i = 0; i < n; i++) {
      final t = n == 1 ? 0.5 : i / (n - 1);
      var edge = 1.0;
      if (t < fade) {
        edge = t / fade;
      } else if (t > 1 - fade) {
        edge = (1 - t) / fade;
      }
      edge = Curves.easeInOut.transform(edge.clamp(0.0, 1.0));
      final sample = i < levels.length ? levels[i].clamp(0.0, 1.0) : 0.0;
      final v = sample;
      final h = (3.5 + v * (size.height - 8)).clamp(3.5, size.height - 2);
      final x = stroke / 2 + i * step;
      paint.color = color.withValues(
        alpha: (muted ? 0.28 : 0.92) * edge,
      );
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.muted != muted || old.color != color || old.levels != levels;
}
