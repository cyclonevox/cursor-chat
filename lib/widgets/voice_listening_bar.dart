import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

String formatVoiceElapsed(Duration elapsed) {
  final s = elapsed.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Cursor-style listening meter: a tape of thin bars that scrolls left.
///
/// [pending] is a shared queue. The recorder appends 0–1 energy samples;
/// this widget consumes them onto the tape so bursts travel instead of
/// jumping in place. Quiet samples still get a little texture so the
/// scroll is visible when nobody is talking.
class VoiceListeningBar extends StatefulWidget {
  const VoiceListeningBar({
    super.key,
    required this.elapsed,
    this.pending,
    this.transcribing = false,
    this.debugLevels,
  });

  /// Live energy samples, oldest first. Mutated by the parent and by this
  /// State. Ignored when [debugLevels] is set.
  final List<double>? pending;
  final Duration elapsed;
  final bool transcribing;

  /// Frozen bars for layout tests. Skips the live ticker.
  final List<double>? debugLevels;

  @override
  State<VoiceListeningBar> createState() => VoiceListeningBarState();
}

class VoiceListeningBarState extends State<VoiceListeningBar>
    with SingleTickerProviderStateMixin {
  static const barCount = 72;
  static const barsPerSecond = 48.0;

  late final Ticker _ticker;
  final List<double> tape = List<double>.generate(barCount + 2, (_) => 0.045);
  double shift = 0;
  Duration _prev = Duration.zero;
  var _primed = false;
  double _live = 0.045;
  int _noise = 1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant VoiceListeningBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    final live = widget.debugLevels == null && !widget.transcribing;
    if (live && !_ticker.isTicking) {
      _primed = false;
      _ticker.start();
    } else if (!live && _ticker.isTicking) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (!_primed) {
      _primed = true;
      _prev = elapsed;
      return;
    }
    var dt = (elapsed - _prev).inMicroseconds / 1e6;
    _prev = elapsed;
    if (dt <= 0) return;
    if (dt > 0.08) dt = 0.08;

    final pending = widget.pending;
    if (pending != null && pending.length > 12) {
      // Audio arrived faster than the tape; catch up so bursts are not lost.
      final extra = pending.length - 8;
      for (var i = 0; i < extra; i++) {
        _commit(_takePending(pending));
      }
    }

    var next = shift + dt * barsPerSecond;
    var steps = 0;
    while (next >= 1 && steps < 16) {
      next -= 1;
      steps++;
      _commit(_takePending(pending));
    }
    shift = next;

    if (_live > 0.06 && (pending == null || pending.isEmpty)) {
      _live *= math.exp(-dt / 0.09);
      if (_live < 0.045) _live = 0.045;
    }
    tape[tape.length - 1] = math.max(_live, 0.04);
    setState(() {});
  }

  double _takePending(List<double>? pending) {
    if (pending != null && pending.isNotEmpty) {
      final v = pending.removeAt(0).clamp(0.0, 1.0);
      _live = math.max(v, 0.04);
      return v < 0.05 ? _floorBar() : v;
    }
    if (_live > 0.08) {
      _live *= 0.72;
      return _live;
    }
    return _floorBar();
  }

  void _commit(double sample) {
    tape.removeAt(0);
    tape.add(sample.clamp(0.0, 1.0));
  }

  double _floorBar() {
    _noise = (_noise * 1103515245 + 12345) & 0x7fffffff;
    return 0.03 + 0.035 * ((_noise % 1000) / 1000.0);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final levels = widget.debugLevels ?? List<double>.from(tape);
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: ClipRect(
                child: CustomPaint(
                  painter: VoiceWavePainter(
                    levels: levels,
                    shift: widget.debugLevels == null ? shift : 0,
                    color: scheme.onSurface,
                    muted: widget.transcribing,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              formatVoiceElapsed(widget.elapsed),
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

class VoiceWavePainter extends CustomPainter {
  VoiceWavePainter({
    required this.levels,
    required this.shift,
    required this.color,
    required this.muted,
  });

  final List<double> levels;
  final double shift;
  final Color color;
  final bool muted;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final n = math.max(levels.length, 1);
    const stroke = 1.35;
    const fade = 0.15;
    final step = size.width / VoiceListeningBarState.barCount;
    final mid = size.height / 2;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    for (var i = 0; i < n; i++) {
      final x = (i - shift) * step + stroke / 2;
      if (x < -stroke || x > size.width + stroke) continue;
      final t = (x / size.width).clamp(0.0, 1.0);
      var edge = 1.0;
      if (t < fade) {
        edge = t / fade;
      } else if (t > 1 - fade) {
        edge = (1 - t) / fade;
      }
      edge = Curves.easeInOut.transform(edge.clamp(0.0, 1.0));
      final sample = i < levels.length ? levels[i].clamp(0.0, 1.0) : 0.0;
      final h = (2.8 + sample * (size.height - 6)).clamp(2.8, size.height - 2);
      paint.color = color.withValues(alpha: (muted ? 0.28 : 0.94) * edge);
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant VoiceWavePainter old) =>
      old.shift != shift ||
      old.muted != muted ||
      old.color != color ||
      old.levels.length != levels.length ||
      !_sameLevels(old.levels, levels);

  static bool _sameLevels(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
