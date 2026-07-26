import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// The app's mark — the isometric cube from the launcher icon, drawn rather
/// than shipped as a bitmap so it scales to any size, tints with the scheme
/// (its three faces ARE the scheme's primary/secondary/tertiary) and can be
/// animated. [lift] tilts the whole solid as if it were being lifted toward the
/// viewer, which the jelly wrappers drive on press.
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 28,
    this.lift = 0,
    this.shadow = true,
  });

  final double size;

  /// -1..1 — how far the cube leans, used for the idle float and press tilt.
  final double lift;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    // Always the literal brand faces, never scheme colours: the palette is the
    // app's, the mark is the mark, and tinting it would just make it a blue box.
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _CubePainter(
          top: kMarkTop,
          left: kMarkLeft,
          right: kMarkRight,
          lift: lift,
          shadow: shadow,
        ),
      ),
    );
  }
}

class _CubePainter extends CustomPainter {
  _CubePainter({
    required this.top,
    required this.left,
    required this.right,
    required this.lift,
    required this.shadow,
  });

  final Color top;
  final Color left;
  final Color right;
  final double lift;
  final bool shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    // The icon's cube is wider than tall and sits slightly low in its box.
    final w = s * 0.42; // half-width of the top rhombus
    final h = s * 0.24; // half-height of the top rhombus
    final d = s * 0.34; // body depth

    // `lift` raises the near corner: the top face opens up, the sides shorten.
    final open = 1 + lift * 0.18;
    final body = d * (1 - lift * 0.12);
    final cy = c.dy - s * 0.04 - lift * s * 0.02;

    final tTop = Offset(c.dx, cy - h * open);
    final tRight = Offset(c.dx + w, cy);
    final tBottom = Offset(c.dx, cy + h * open);
    final tLeft = Offset(c.dx - w, cy);

    final p = Paint()..isAntiAlias = true;

    if (shadow) {
      canvas.drawPath(
        Path()
          ..moveTo(tLeft.dx, tLeft.dy + body)
          ..lineTo(tBottom.dx, tBottom.dy + body)
          ..lineTo(tRight.dx, tRight.dy + body)
          ..lineTo(tBottom.dx, tBottom.dy + body + h * 0.7)
          ..close(),
        p
          ..color = Colors.black.withValues(alpha: 0.28)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      p.maskFilter = null;
    }

    // Left face.
    canvas.drawPath(
      Path()
        ..moveTo(tLeft.dx, tLeft.dy)
        ..lineTo(tBottom.dx, tBottom.dy)
        ..lineTo(tBottom.dx, tBottom.dy + body)
        ..lineTo(tLeft.dx, tLeft.dy + body)
        ..close(),
      p..color = left,
    );

    // Right face.
    canvas.drawPath(
      Path()
        ..moveTo(tRight.dx, tRight.dy)
        ..lineTo(tBottom.dx, tBottom.dy)
        ..lineTo(tBottom.dx, tBottom.dy + body)
        ..lineTo(tRight.dx, tRight.dy + body)
        ..close(),
      p..color = right,
    );

    // Top face last so its edges stay crisp over the sides.
    canvas.drawPath(
      Path()
        ..moveTo(tTop.dx, tTop.dy)
        ..lineTo(tRight.dx, tRight.dy)
        ..lineTo(tBottom.dx, tBottom.dy)
        ..lineTo(tLeft.dx, tLeft.dy)
        ..close(),
      p..color = top,
    );
  }

  @override
  bool shouldRepaint(_CubePainter old) =>
      old.lift != lift ||
      old.top != top ||
      old.left != left ||
      old.right != right ||
      old.shadow != shadow;
}

/// The mark, breathing. A slow, small vertical float with the tilt following
/// it — enough to read as alive on an otherwise still screen (the root-request
/// and empty states), never enough to distract.
class FloatingBrandMark extends StatefulWidget {
  const FloatingBrandMark({super.key, this.size = 96});

  final double size;

  @override
  State<FloatingBrandMark> createState() => _FloatingBrandMarkState();
}

class _FloatingBrandMarkState extends State<FloatingBrandMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final phase = math.sin(_c.value * 2 * math.pi);
          return Transform.translate(
            offset: Offset(0, -phase * widget.size * 0.035),
            child: BrandMark(size: widget.size, lift: phase * 0.5),
          );
        },
      ),
    );
  }
}
