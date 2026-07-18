import 'package:flutter/material.dart';

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

/// A floating, icon-only bottom bar. It hovers above the content (the Scaffold
/// uses `extendBody`), is sized to its icons so there's no empty gutter, and
/// marks the active tab with a single sliding tablet.
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
  static const double _barRadius = 22; // rounded-square bar, not a full stadium
  static const double _tabRadius = 16; // rounded-square selection chip

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
                  // second tap mid-slide redirects it instead of queueing.
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    top: 0,
                    bottom: 0,
                    left: _cell * index,
                    width: _cell,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(_tabRadius),
                      ),
                    ),
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
    // the sliding tablet and the haptic tick are the feedback.
    return SizedBox(
      width: width,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
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
