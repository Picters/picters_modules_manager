import 'package:flutter/material.dart';

import 'widgets.dart';

/// One destination in [AppBottomBar].
class BottomBarItem {
  const BottomBarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;

  /// Not drawn (the bar is icon-only) — used as the accessibility label.
  final String label;
}

/// A floating, icon-only bottom bar: a stadium-shaped dock hovering above the
/// content (the Scaffold uses `extendBody`), sized to its icons so there's no
/// empty gutter, with the active tab marked by a single sliding chip.
///
/// The chip's corners are position-dependent. At either end the outward side
/// rounds off to match the dock's own semicircular end and the inward side
/// stays squared, so the chip caps the bar; anywhere in between both sides are
/// squared. The transition is continuous rather than stepped — see the builder.
///
/// Why custom: Material's [NavigationBar] animates each destination's label
/// independently, so rapid switches make the new label wait for the old pill to
/// settle. Here the only moving part is one [AnimatedPositioned] tablet — tap
/// again mid-slide and it just retargets, so fast taps feel instant.
class AppBottomBar extends StatelessWidget {
  const AppBottomBar({
    super.key,
    required this.index,
    required this.items,
    required this.onSelect,
  });

  final int index;
  final List<BottomBarItem> items;
  final ValueChanged<int> onSelect;

  static const double _cell = 60; // width per icon
  static const double _height = 56; // inner (tablet) height
  static const double _gap = 6; // padding between the tablet and the bar edge

  /// Full stadium: half the bar's outer height (_height + 2 * _gap), so both
  /// ends are true semicircles rather than merely generous corners.
  static const double _barRadius = (_height + 2 * _gap) / 2;

  /// The chip's rounded side. Half its own height — and, not by accident,
  /// exactly `_barRadius - _gap`, which is the radius the bar's inner edge
  /// traces. A chip parked at either end therefore nests into that end
  /// concentrically, with the 6px gap even the whole way round the curve.
  static const double _tabRound = _height / 2;

  /// The chip's "squared" side — the rounded-rectangle corner the chip had
  /// before the ends started morphing. Softer than a true square on purpose:
  /// the contrast against the round side still reads clearly, and the corner
  /// stays in the same family of shapes as the cards and buttons.
  static const double _tabSquare = 16;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = items.length;

    // Row (not Center): the Scaffold measures a bottomNavigationBar with the
    // full screen height as a loose max, and Center/Align would expand into all
    // of it and float the pill in the middle. A Row shrink-wraps vertically to
    // the pill's height while still centring it horizontally, so it sits at the
    // bottom where it belongs.
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Material(
          color: scheme.surfaceContainerHigh,
          elevation: 3,
          shadowColor: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(_barRadius),
          child: Padding(
            padding: const EdgeInsets.all(_gap),
            child: SizedBox(
              height: _height,
              width: _cell * n,
              child: Stack(
                children: [
                  // The one moving element — retargets on every rebuild, so a
                  // second tap mid-slide redirects it instead of queueing. It
                  // just glides: no jelly stretch here, the squish belongs to
                  // the icons. easeOutCubic also stops AT the target, so it
                  // never overshoots past the end cell.
                  //
                  // Animating the *index* as a continuous value (rather than
                  // AnimatedPositioned over the offset) is what lets the corners
                  // morph in step with the travel: position and radii are both
                  // derived from the same number, so the chip is already
                  // un-rounding as it leaves an end instead of popping shape
                  // once it arrives.
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: index.toDouble()),
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    builder: (context, pos, _) {
                      // How far into an end cell the chip currently sits, 1 at
                      // the end and 0 by the time it reaches its neighbour.
                      final atLeft = (1 - pos).clamp(0.0, 1.0);
                      final atRight = (pos - (n - 2)).clamp(0.0, 1.0);
                      double radius(double t) =>
                          _tabSquare + (_tabRound - _tabSquare) * t;
                      return Positioned(
                        top: 0,
                        bottom: 0,
                        left: _cell * pos,
                        width: _cell,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            // Only the side facing an end goes round; the side
                            // facing the rest of the bar stays squared, so the
                            // chip reads as capping the bar there rather than
                            // floating inside it. In the middle both sides are
                            // squared and it's a plain block.
                            borderRadius: BorderRadius.horizontal(
                              left: Radius.circular(radius(atLeft)),
                              right: Radius.circular(radius(atRight)),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  // Positioned.fill so the cells span the bar's full height and
                  // centre their icons, instead of pinning to the Stack's top.
                  Positioned.fill(
                    child: Row(
                      children: [
                        for (var i = 0; i < n; i++)
                          _IconCell(
                            item: items[i],
                            selected: i == index,
                            width: _cell,
                            onTap: () => onSelect(i),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ],
      ),
    );
  }
}

class _IconCell extends StatelessWidget {
  const _IconCell({
    required this.item,
    required this.selected,
    required this.width,
    required this.onTap,
  });

  final BottomBarItem item;
  final bool selected;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Flips instantly — no per-item animation to fall out of sync when taps
    // come fast; the shared tablet carries all the motion.
    final color =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    // GestureDetector, not InkResponse: no white ripple/splash on the dock —
    // the jelly press, the sliding tablet and the haptic tick are the feedback.
    return SizedBox(
      width: width,
      child: JellyTap(
        onTap: onTap,
        child: Semantics(
          label: item.label,
          button: true,
          selected: selected,
          child: Center(
            child: Icon(
              selected ? item.selectedIcon : item.icon,
              size: 25,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
