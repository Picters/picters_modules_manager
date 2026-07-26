import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// EXPERIMENT — "liquid glass" surfaces, iOS-style.
///
/// Everything in this file is behind [kLiquidGlass]. Flip it to false and every
/// widget here falls back to exactly the surface the app used before, so the
/// look can be pulled without touching a single call site. Deleting the branch
/// removes it entirely.
const bool kLiquidGlass = true;

/// How hard the frost blurs whatever is behind it.
const double _kBlur = 24;

/// A card. With glass on it's a frosted, translucent panel with a lit top edge;
/// with glass off it's the plain `Card.outlined` the app shipped with.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.radius = 16,
    this.clipBehavior,
  });

  final Widget child;
  final double radius;

  /// Only meaningful with glass off — the frosted path always clips to its
  /// own rounded rect.
  final Clip? clipBehavior;

  @override
  Widget build(BuildContext context) {
    if (!kLiquidGlass) {
      return Card.outlined(clipBehavior: clipBehavior, child: child);
    }

    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: _kBlur, sigmaY: _kBlur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            // A vertical wash rather than a flat fill: glass catches more light
            // at the top edge than at the bottom, and that gradient is most of
            // what sells it as a surface with thickness.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: dark
                  ? [
                      Colors.white.withValues(alpha: 0.09),
                      Colors.white.withValues(alpha: 0.035),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.72),
                      Colors.white.withValues(alpha: 0.52),
                    ],
            ),
            border: Border.all(
              color: dark
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.white.withValues(alpha: 0.7),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The same treatment for a free-standing panel that sets its own padding and
/// radius — hero cards, the dock. [tint] lets a live surface (Inject on, a
/// capped profile) pull the accent through the glass.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 22,
    this.tint,
    this.padding,
    this.elevated = false,
  });

  final Widget child;
  final double radius;
  final Color? tint;
  final EdgeInsetsGeometry? padding;

  /// Adds a drop shadow — for surfaces that float over content (the dock).
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    if (!kLiquidGlass) {
      return Container(
        padding: padding,
        decoration: BoxDecoration(
          color: tint == null
              ? scheme.surfaceContainerHigh
              : Color.alphaBlend(
                  tint!.withValues(alpha: 0.09),
                  scheme.surfaceContainerHigh,
                ),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: tint?.withValues(alpha: 0.45) ?? Colors.transparent,
            width: 1.5,
          ),
        ),
        child: child,
      );
    }

    final glass = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: _kBlur, sigmaY: _kBlur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? [
                      Colors.white.withValues(alpha: 0.11),
                      Colors.white.withValues(alpha: 0.04),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.78),
                      Colors.white.withValues(alpha: 0.55),
                    ],
            ),
            border: Border.all(
              color: tint != null
                  ? tint!.withValues(alpha: dark ? 0.55 : 0.5)
                  : (dark
                        ? Colors.white.withValues(alpha: 0.16)
                        : Colors.white.withValues(alpha: 0.75)),
              width: 1.2,
            ),
          ),
          // The accent glows through the pane from one corner instead of
          // flooding it, so a live card reads as lit rather than painted.
          child: tint == null
              ? child
              : DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-0.8, -1),
                      radius: 1.5,
                      colors: [
                        tint!.withValues(alpha: dark ? 0.20 : 0.16),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: child,
                ),
        ),
      ),
    );

    if (!elevated) return glass;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.5 : 0.16),
            blurRadius: 26,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: glass,
    );
  }
}

/// Slow-drifting colour behind the whole app. Glass needs something to refract:
/// over a flat near-black page a blur has nothing to work with and the panels
/// just look like grey boxes. Off entirely when [kLiquidGlass] is false.
class GlassBackdrop extends StatefulWidget {
  const GlassBackdrop({super.key, required this.child});

  final Widget child;

  @override
  State<GlassBackdrop> createState() => _GlassBackdropState();
}

class _GlassBackdropState extends State<GlassBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 26),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kLiquidGlass) return widget.child;

    final scheme = Theme.of(context).colorScheme;
    // Respect the platform's reduce-motion setting: the wash stays, it just
    // stops drifting.
    final still = MediaQuery.disableAnimationsOf(context);

    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                painter: _AuroraPainter(
                  t: still ? 0.2 : _c.value,
                  a: scheme.primary,
                  b: scheme.tertiary,
                  c: scheme.secondary,
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({
    required this.t,
    required this.a,
    required this.b,
    required this.c,
  });

  final double t;
  final Color a;
  final Color b;
  final Color c;

  void _blob(Canvas canvas, Size size, Offset at, double r, Color color) {
    canvas.drawCircle(
      at,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: 0.30), Colors.transparent],
        ).createShader(Rect.fromCircle(center: at, radius: r)),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = t * 2 * math.pi;
    _blob(
      canvas,
      size,
      Offset(w * (0.18 + 0.10 * math.sin(p)), h * 0.16),
      w * 0.72,
      a,
    );
    _blob(
      canvas,
      size,
      Offset(w * (0.86 - 0.12 * math.sin(p * 0.8 + 1.4)), h * 0.44),
      w * 0.62,
      b,
    );
    _blob(
      canvas,
      size,
      Offset(w * (0.45 + 0.14 * math.sin(p * 0.6 + 3.0)), h * 0.86),
      w * 0.70,
      c,
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.t != t || old.a != a || old.b != b || old.c != c;
}
