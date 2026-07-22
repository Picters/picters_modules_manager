import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoSliverRefreshControl, RefreshIndicatorMode;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'module_info.dart';
import 'theme.dart';

/// A copyable dialog for a captured dmesg tail — shared by any failure path
/// that surfaces [ModuleRepository]'s diagnostics (Wi-Fi mode switch, plain
/// module toggle) instead of just an opaque "didn't work" message.
void showDiagnosticsDialog(BuildContext context, String dmesgTail) {
  final scheme = Theme.of(context).colorScheme;
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.bug_report_outlined),
      title: const Text('Diagnostics'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: SingleChildScrollView(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              dmesgTail.isEmpty ? '(no matching dmesg lines)' : dmesgTail,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.tonalIcon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: dmesgTail));
            Navigator.of(context).pop();
            showInfo(context, 'Diagnostics copied to clipboard.');
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy'),
        ),
      ],
    ),
  );
}

/// Yes/no confirmation for a hard-to-undo action (currently the reboot the
/// stuck-stock-Wi-Fi recovery offers). Returns true only if confirmed.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Confirmation shown when a module can't load until other modules are up: it
/// names them and offers to enable all of them (in dependency order) plus the
/// target in one go. Returns true if confirmed.
Future<bool?> showDependencyDialog(
  BuildContext context, {
  required String module,
  required List<String> deps,
}) {
  return _dependencyDialog(
    context,
    icon: Icons.account_tree_outlined,
    title: 'Enable required modules?',
    lead: '$module needs these modules loaded first:',
    modules: deps,
    note: "They'll be enabled in order, then $module.",
    confirmLabel: 'Enable all',
  );
}

/// Confirmation shown when unloading a module that others still depend on: it
/// names the dependents and offers to unload them first. Returns true if
/// confirmed.
Future<bool?> showDependentsDialog(
  BuildContext context, {
  required String module,
  required List<String> dependents,
}) {
  return _dependencyDialog(
    context,
    icon: Icons.link_off,
    title: 'Unload dependent modules?',
    lead: '$module is still in use by:',
    modules: dependents,
    note: "They'll be unloaded first, then $module.",
    confirmLabel: 'Unload all',
  );
}

Future<bool?> _dependencyDialog(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String lead,
  required List<String> modules,
  required String note,
  required String confirmLabel,
}) {
  final scheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(icon),
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(lead, style: textTheme.bodyMedium),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in modules)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    m,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            note,
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

/// Interface chooser for Reconfigure when more than one adapter interface is
/// live: one tappable tile per interface (name, driver, monitor/managed, up/
/// down). Returns the chosen [WifiInterface], or null if cancelled.
Future<WifiInterface?> showInterfacePicker(
  BuildContext context, {
  required List<WifiInterface> interfaces,
}) {
  final scheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;
  return showDialog<WifiInterface>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.settings_input_antenna),
      title: const Text('Select interface to initialise'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final i in interfaces)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.of(context).pop(i),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Icon(
                          i.monitor ? Icons.radar : Icons.wifi,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                i.name,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${i.driver.isEmpty ? "no driver" : i.driver} · '
                                '${i.monitor ? "monitor" : "managed"} · '
                                '${i.up ? "up" : "down"}',
                                style: textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

/// Pops [builder] open from [origin] (the tap's global position) as a card
/// centred on screen — it grows smoothly from that point and fades in (no
/// bounce/overshoot), reading as the row unfolding into the panel. Dismiss by
/// tapping the scrim or popping the route.
Future<T?> showJellyPanel<T>(
  BuildContext context, {
  required Offset origin,
  required WidgetBuilder builder,
}) {
  final size = MediaQuery.sizeOf(context);
  final align = Alignment(
    (origin.dx / size.width * 2 - 1).clamp(-1.0, 1.0),
    (origin.dy / size.height * 2 - 1).clamp(-1.0, 1.0),
  );
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (context, _, _) => Center(child: Builder(builder: builder)),
    transitionBuilder: (context, animation, secondary, child) {
      // Plain ease-out grow — no spring overshoot on open.
      final grow = 0.9 + 0.1 * Curves.easeOutCubic.transform(animation.value);
      final fade = Curves.easeOut.transform(animation.value.clamp(0.0, 1.0));
      return Opacity(
        opacity: fade,
        child: Transform.scale(scale: grow, alignment: align, child: child),
      );
    },
  );
}

/// A soft pulsing dot — the "live / active" cue on the Inject hero card.
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0)
            .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: widget.color.withValues(alpha: 0.6), blurRadius: 6),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps a tappable child in a "jelly" reaction: the instant you touch it, it
/// dips and tilts in 3D *toward the exact point you pressed* (poke the corner →
/// that corner sinks) and squashes; on release it springs back past its resting
/// size with a wobble. Replaces the ink ripple. The tilt lands immediately on
/// press (not after a hold), so even a quick tap reads as jelly.
class JellyTap extends StatefulWidget {
  const JellyTap({
    super.key,
    required this.child,
    this.onTap,
    this.pressScale = 0.92,
    this.tilt = 0.20,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// How far it compresses while held.
  final double pressScale;

  /// Max perspective tilt (radians) toward the press point.
  final double tilt;

  @override
  State<JellyTap> createState() => _JellyTapState();
}

class _JellyTapState extends State<JellyTap>
    with SingleTickerProviderStateMixin {
  // 0 = rest, 1 = fully pressed. Unbounded so the spring release overshoots
  // below 0 — the wobble past the resting size (the "hit the wall" bounce).
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 0);
  static const _spring = SpringDescription(mass: 1, stiffness: 300, damping: 11);

  // Where on the child the press landed, in [-1, 1] from centre.
  Alignment _at = Alignment.center;

  void _press(TapDownDetails d) {
    final box = context.findRenderObject() as RenderBox?;
    final s = box?.size;
    if (s != null && s.width > 0 && s.height > 0) {
      _at = Alignment(
        (d.localPosition.dx / s.width * 2 - 1).clamp(-1.0, 1.0),
        (d.localPosition.dy / s.height * 2 - 1).clamp(-1.0, 1.0),
      );
    } else {
      _at = Alignment.center;
    }
    // Snap to pressed almost instantly so the tilt shows on a quick tap too.
    _c.animateTo(1,
        duration: const Duration(milliseconds: 45), curve: Curves.easeOut);
  }

  void _release() =>
      _c.animateWith(SpringSimulation(_spring, _c.value, 0, _c.velocity));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _press,
      onTapUp: (_) {
        _release();
        widget.onTap?.call();
      },
      onTapCancel: _release,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final p = _c.value.clamp(-0.35, 1.0); // <0 = release overshoot
          final tiltAmt = p.clamp(0.0, 1.0);
          final base = 1 - (1 - widget.pressScale) * p; // pressed<1, wobble>1
          final squash = p * 0.5 * (1 - widget.pressScale);
          final m = Matrix4.identity()
            ..setEntry(3, 2, 0.0016) // perspective
            ..rotateX(-_at.y * widget.tilt * tiltAmt)
            ..rotateY(_at.x * widget.tilt * tiltAmt)
            ..scaleByDouble(base + squash, base - squash, 1.0, 1.0);
          return Transform(
            alignment: Alignment.center,
            transform: m,
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// Gives a sliding tablet a "flings, then slams into the wall and squishes"
/// jelly reaction whenever [trigger] changes. The squash is anchored to the
/// LEADING (travel-direction) edge, so the tablet compresses *toward* the wall
/// it arrives at instead of wobbling symmetrically — reads as hitting it. Pair
/// with a no-overshoot position curve (easeOutCubic) so it never crosses the
/// wall, only presses into it.
class JellyStretch extends StatefulWidget {
  const JellyStretch({
    super.key,
    required this.trigger,
    required this.child,
    this.horizontal = true,
    this.amount = 0.16,
  });

  /// Change this to fire the wobble (e.g. the selected index / left offset).
  final Object trigger;
  final Widget child;

  /// Stretch axis — true = horizontal travel (bottom bar / segmented).
  final bool horizontal;
  final double amount;

  @override
  State<JellyStretch> createState() => _JellyStretchState();
}

class _JellyStretchState extends State<JellyStretch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  // +1 = travelled toward the higher index (right / down), -1 = the other way.
  // The scale is anchored to that edge so the squish presses into that wall.
  double _dir = 1;

  @override
  void didUpdateWidget(JellyStretch old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) {
      final a = old.trigger, b = widget.trigger;
      if (a is num && b is num) _dir = b >= a ? 1 : -1;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        // Flings out (stretch, trailing edge lags) then, on impact, compresses
        // toward the wall (squish), springing back — a decaying oscillation.
        final env = t >= 1
            ? 0.0
            : math.sin(t * math.pi * 2) * (1 - t) * (1 - t) * widget.amount;
        final align = widget.horizontal
            ? Alignment(_dir, 0)
            : Alignment(0, _dir);
        return Transform.scale(
          scaleX: widget.horizontal ? 1 + env : 1 - env,
          scaleY: widget.horizontal ? 1 - env : 1 + env,
          alignment: align,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

TextStyle sectionLabelStyle(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return Theme.of(context)
      .textTheme
      .labelLarge!
      .copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700, letterSpacing: 0.3);
}

/// A section title row: optional leading icon, a label, and an optional
/// trailing count pill — the one section header used across both screens.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, this.icon, required this.label, this.trailing});

  final IconData? icon;
  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, color: scheme.onSurfaceVariant, size: 19),
          const SizedBox(width: 8),
        ],
        Expanded(child: Text(label, style: sectionLabelStyle(context))),
        if (trailing != null) CountPill(text: trailing!),
      ],
    );
  }
}

/// A small rounded count/label chip (e.g. "2 / 5" loaded).
class CountPill extends StatelessWidget {
  const CountPill({super.key, required this.text, this.highlight = false});

  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: highlight ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: highlight ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// A single flat divider — the one row separator used app-wide.
class CardDivider extends StatelessWidget {
  const CardDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, thickness: 1, indent: 16, endIndent: 16);
  }
}

/// Fades + slides a child in once, on first mount — used for every
/// top-level card/section.
class FadeInSlide extends StatefulWidget {
  const FadeInSlide({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, 0.08),
    this.scaleFrom = 0.94,
    this.curve = Curves.easeOutBack,
    this.duration = const Duration(milliseconds: 520),
  });

  final Widget child;
  final Duration delay;
  final Offset offset;
  final double scaleFrom;
  final Curve curve;
  final Duration duration;

  @override
  State<FadeInSlide> createState() => _FadeInSlideState();
}

class _FadeInSlideState extends State<FadeInSlide> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween(begin: widget.offset, end: Offset.zero)
      .animate(CurvedAnimation(parent: _controller, curve: widget.curve));
  late final Animation<double> _scale = Tween(begin: widget.scaleFrom, end: 1.0)
      .animate(CurvedAnimation(parent: _controller, curve: widget.curve));

  @override
  void initState() {
    super.initState();
    // Start on this frame when there's no stagger — routing a zero delay
    // through Future.delayed still costs an event-loop turn, which reads as a
    // beat of lag before the card appears.
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: ScaleTransition(
          scale: _scale,
          alignment: Alignment.topCenter,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Reveals a row by fading and easing it up into its slot. It does NOT animate
/// height — the parent's single AnimatedSize owns that, so nested size
/// animators can't fight and jitter the list.
class RowReveal extends StatefulWidget {
  const RowReveal({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 340),
  });

  final Widget child;
  final Duration delay;
  final Duration duration;

  @override
  State<RowReveal> createState() => _RowRevealState();
}

class _RowRevealState extends State<RowReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween(
    begin: const Offset(0, 0.14),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutBack));

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// Cross-fades + resizes between two states of the same section (e.g. an
/// empty placeholder vs. a populated list) instead of snapping instantly.
class AnimatedSection extends StatelessWidget {
  const AnimatedSection({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: child,
      ),
    );
  }
}

/// The app's loading indicator, in the Android 17 / Material 3 Expressive
/// language: a soft-cornered polygon that continuously morphs between a
/// triangle, square, pentagon and hexagon while it spins. Used everywhere a
/// spinner used to be, and as the pull-to-refresh glyph.
class MorphingPolygon extends StatefulWidget {
  const MorphingPolygon({super.key, this.size = 34, required this.color});

  final double size;
  final Color color;

  @override
  State<MorphingPolygon> createState() => _MorphingPolygonState();
}

class _MorphingPolygonState extends State<MorphingPolygon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: _PolygonPainter(t: _c.value, color: widget.color),
          ),
        ),
      ),
    );
  }
}

class _PolygonPainter extends CustomPainter {
  _PolygonPainter({required this.t, required this.color});

  final double t;
  final Color color;

  // The shapes it cycles through, by lobe count.
  static const _lobes = <int>[3, 4, 5, 6, 4];
  static const _amp = 0.17; // how pronounced the corners read
  static const _steps = 72; // enough for a smooth ≤34px glyph; half the per-frame trig

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;

    final span = _lobes.length;
    final scaled = t * span;
    final i = scaled.floor() % span;
    final blend = Curves.easeInOut.transform(scaled - scaled.floorToDouble());
    final nA = _lobes[i].toDouble();
    final nB = _lobes[(i + 1) % span].toDouble();
    final phase = t * 2 * math.pi; // continuous rotation

    final path = Path();
    for (var k = 0; k <= _steps; k++) {
      final theta = (k / _steps) * 2 * math.pi;
      final lobe = _lerp(math.cos(nA * theta), math.cos(nB * theta), blend);
      final r = radius * (1 + _amp * lobe) / (1 + _amp);
      final a = theta + phase;
      final p = center + Offset(math.cos(a), math.sin(a)) * r;
      if (k == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();

    canvas.drawPath(path, Paint()..color = color..isAntiAlias = true);
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(_PolygonPainter old) => old.t != t || old.color != color;
}

/// A scrollable list with the app's own Android-17-style pull-to-refresh: an
/// overscroll reveals the [MorphingPolygon] instead of the stock circular
/// spinner. Built on a Cupertino sliver refresh control so the whole indicator
/// is ours to draw.
class PolygonScrollView extends StatelessWidget {
  const PolygonScrollView({
    super.key,
    required this.onRefresh,
    required this.padding,
    required this.children,
  });

  final Future<void> Function() onRefresh;
  final EdgeInsets padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    // Cap content width and centre it on wide screens (tablet / landscape),
    // where one full-width column would otherwise stretch out and look sparse.
    final width = MediaQuery.sizeOf(context).width;
    const maxContent = 640.0;
    final side = width > maxContent ? (width - maxContent) / 2 : 0.0;
    final effectivePadding = EdgeInsets.fromLTRB(
      padding.left + side,
      padding.top,
      padding.right + side,
      padding.bottom,
    );
    return CustomScrollView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      slivers: [
        CupertinoSliverRefreshControl(
          onRefresh: () {
            HapticFeedback.mediumImpact();
            return onRefresh();
          },
          refreshTriggerPullDistance: 120,
          refreshIndicatorExtent: 86,
          builder: (context, mode, pulled, triggerDistance, indicatorExtent) {
            final t = (pulled / triggerDistance).clamp(0.0, 1.0);
            final showing = mode != RefreshIndicatorMode.inactive;
            return Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Opacity(
                  opacity: showing ? Curves.easeOut.transform(t) : 0,
                  child: Transform.scale(
                    scale: 0.55 + 0.45 * t,
                    child: MorphingPolygon(size: 34, color: color),
                  ),
                ),
              ),
            );
          },
        ),
        SliverPadding(
          padding: effectivePadding,
          sliver: SliverList(delegate: SliverChildListDelegate(children)),
        ),
      ],
    );
  }
}
