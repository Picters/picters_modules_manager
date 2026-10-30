import 'package:flutter/material.dart';

/// A continuous track with a detached Off endpoint; snapping stays discrete.
class LimitSliderTrack extends SliderTrackShape with BaseSliderTrackShape {
  const LimitSliderTrack({this.normalEnd = 40 / 45});
  final double normalEnd;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final end = rect.left + rect.width * normalEnd;
    final off = thumbCenter.dx > end + 2;
    final active = isEnabled
        ? sliderTheme.activeTrackColor!
        : sliderTheme.disabledActiveTrackColor!;
    final inactive = isEnabled
        ? sliderTheme.inactiveTrackColor!
        : sliderTheme.disabledInactiveTrackColor!;
    final canvas = context.canvas;
    void segment(double left, double right, Color color) {
      if (right <= left) return;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(left, rect.top, right, rect.bottom),
          Radius.circular(rect.height / 2),
        ),
        Paint()..color = color,
      );
    }

    if (off) {
      segment(rect.left, end, active);
    } else {
      // Leave a gap around the handle, and stop exactly under it at the last regular step.
      segment(rect.left, (thumbCenter.dx - 5).clamp(rect.left, end), active);
      segment((thumbCenter.dx + 5).clamp(rect.left, end), end, inactive);
    }
  }
}

/// The detached circle replaces the handle in Off mode without shifting layout.
class LimitSliderHandle extends SliderComponentShape {
  const LimitSliderHandle({required this.hidden});
  final bool hidden;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(4, 44);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    if (hidden) return;
    const HandleThumbShape().paint(
      context,
      center,
      activationAnimation: activationAnimation,
      enableAnimation: enableAnimation,
      isDiscrete: isDiscrete,
      labelPainter: labelPainter,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      textDirection: textDirection,
      value: value,
      textScaleFactor: textScaleFactor,
      sizeWithOverflow: sizeWithOverflow,
    );
  }
}
