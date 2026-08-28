import 'dart:ui';

import 'package:flutter/material.dart';

/// niri-like frosted chrome: blur whatever is painted behind, then a
/// translucent tint. Used on Android and Linux so the bars match the
/// compositor glass look.
class FrostedSurface extends StatelessWidget {
  const FrostedSurface({
    super.key,
    required this.child,
    this.sigma = 40,
    this.tint,
    this.borderRadius,
    this.border,
  });

  final Widget child;
  final double sigma;
  final Color? tint;
  final BorderRadius? borderRadius;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = tint ?? scheme.surface.withValues(alpha: dark ? 0.38 : 0.52);
    final radius = borderRadius;
    Widget panel = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: radius,
          border: border,
        ),
        child: child,
      ),
    );
    if (radius != null) {
      panel = ClipRRect(borderRadius: radius, child: panel);
    } else {
      panel = ClipRect(child: panel);
    }
    return panel;
  }
}

/// Full-bleed frost for an [AppBar.flexibleSpace], including the status bar.
class FrostedBar extends StatelessWidget {
  const FrostedBar({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FrostedSurface(
      sigma: 44,
      border: Border(
        bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.28)),
      ),
      child: const SizedBox.expand(),
    );
  }
}
