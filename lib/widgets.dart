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
        Jelly(child: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        )),
        Jelly(child: FilledButton.tonalIcon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: dmesgTail));
            Navigator.of(context).pop();
            showInfo(context, 'Diagnostics copied to clipboard.');
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy'),
        )),
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
        Jelly(child: TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        )),
        Jelly(child: FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          child: Text(confirmLabel),
        )),
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
        Jelly(child: TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        )),
        Jelly(child: FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        )),
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
        Jelly(child: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        )),
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

/// The spring every jelly reaction releases with. Deliberately underdamped
/// (ζ ≈ 0.23) so the rebound reads as two or three decaying wobbles rather
/// than one bounce — that settling is what makes it look like a soft body
/// instead of a scaled widget.
const SpringDescription kJellySpring =
    SpringDescription(mass: 1, stiffness: 380, damping: 9);

/// The one deformation behind every jelly reaction, so a button, a row and a
/// switch thumb all behave identically.
///
/// [p] is the press amount: 1 held, 0 at rest, negative while the release
/// overshoots. Strictly 2D — it sinks and widens, then springs back and wobbles.
/// No perspective, no tilt, no shear: the squash-and-stretch alone carries the
/// softness, and it stays flat.
///
/// Returns the (scaleX, scaleY) pair. One axis compresses while the other
/// bulges by the same amount, so the area stays roughly constant and it reads
/// as displaced volume rather than as a widget getting smaller.
({double x, double y}) jellyScale({
  required double p,
  required double pressScale,
}) {
  final base = 1 - (1 - pressScale) * p;
  final bulge = p * 0.55 * (1 - pressScale);
  return (x: base + bulge, y: base - bulge);
}

/// Drives [jellyTransform] from raw pointer events *without consuming them*, so
/// it can be wrapped around widgets that handle their own gestures — a
/// FilledButton, a ListTile, a Switch — and they keep working exactly as
/// before while gaining the reaction. For a bare tappable with no gesture
/// handling of its own, use [JellyTap].
class Jelly extends StatefulWidget {
  const Jelly({
    super.key,
    required this.child,
    this.pressScale = 0.94,
    this.enabled = true,
  });

  final Widget child;
  final double pressScale;
  final bool enabled;

  @override
  State<Jelly> createState() => _JellyState();
}

class _JellyState extends State<Jelly> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 0);

  void _down() => _c.animateTo(1,
      duration: const Duration(milliseconds: 45), curve: Curves.easeOut);

  void _up() =>
      _c.animateWith(SpringSimulation(kJellySpring, _c.value, 0, _c.velocity));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      // Listener observes; it never claims the gesture, so the child's own
      // onTap/onChanged still fires.
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final s = jellyScale(
            p: _c.value.clamp(-0.35, 1.0),
            pressScale: widget.pressScale,
          );
          return Transform.scale(scaleX: s.x, scaleY: s.y, child: child);
        },
        child: widget.child,
      ),
    );
  }
}

/// Wraps a tappable child in a "jelly" reaction: the instant you touch it, it
/// sinks and widens; on release it springs back past its resting size and
/// wobbles down. Replaces the ink ripple. The reaction lands immediately on
/// press (not after a hold), so even a quick tap reads as jelly. This one OWNS
/// the tap — use [Jelly] to decorate a widget that already handles its own.
class JellyTap extends StatefulWidget {
  const JellyTap({
    super.key,
    required this.child,
    this.onTap,
    this.pressScale = 0.93,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// How far it compresses while held.
  final double pressScale;

  @override
  State<JellyTap> createState() => _JellyTapState();
}

class _JellyTapState extends State<JellyTap>
    with SingleTickerProviderStateMixin {
  // 0 = rest, 1 = fully pressed. Unbounded so the spring release overshoots
  // below 0 — the wobble past the resting size (the "hit the wall" bounce).
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 0);

  // Snap to pressed almost instantly so it shows on a quick tap too.
  void _press(TapDownDetails _) => _c.animateTo(1,
      duration: const Duration(milliseconds: 45), curve: Curves.easeOut);

  void _release() =>
      _c.animateWith(SpringSimulation(kJellySpring, _c.value, 0, _c.velocity));

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
          final s = jellyScale(
            p: _c.value.clamp(-0.35, 1.0),
            pressScale: widget.pressScale,
          );
          return Transform.scale(scaleX: s.x, scaleY: s.y, child: child);
        },
        child: widget.child,
      ),
    );
  }
}

/// The app's switch. The thumb is a blob, not a disc: it stretches along the
/// direction it's travelling (fast move → longer blob), slams into the far end
/// and squashes against it, then settles. Pressing it dents it first. The
/// stretch is derived from the spring's own velocity, so it's the motion that
/// deforms the shape rather than a canned animation played over it.
class JellySwitch extends StatefulWidget {
  const JellySwitch({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<JellySwitch> createState() => _JellySwitchState();
}

class _JellySwitchState extends State<JellySwitch>
    with SingleTickerProviderStateMixin {
  static const _w = 54.0;
  static const _h = 32.0;
  static const _thumb = 24.0;

  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: widget.value ? 1 : 0);
  // Stiffer and better damped than the tap spring: a switch should arrive
  // decisively, with the wobble in the shape rather than the position.
  static const _travel = SpringDescription(mass: 1, stiffness: 300, damping: 17);

  bool _held = false;

  @override
  void didUpdateWidget(JellySwitch old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _c.animateWith(
        SpringSimulation(_travel, _c.value, widget.value ? 1 : 0, _c.velocity),
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onChanged != null;
    return Listener(
      onPointerDown: (_) => setState(() => _held = true),
      onPointerUp: (_) => setState(() => _held = false),
      onPointerCancel: (_) => setState(() => _held = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => widget.onChanged!(!widget.value) : null,
        child: SizedBox(
          width: _w,
          height: _h,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value.clamp(-0.15, 1.15);
              final on = t.clamp(0.0, 1.0);
              // Velocity → stretch along travel; held → a symmetrical dent.
              final v = (_c.velocity / 26).clamp(-1.0, 1.0).abs();
              final stretch = v * 0.30 + (_held ? 0.10 : 0);
              final trackOn = Color.lerp(
                  scheme.surfaceContainerHighest, scheme.primary, on)!;
              final thumbColor =
                  Color.lerp(scheme.outline, scheme.onPrimary, on)!;
              final travel = _w - _thumb - 8;
              final dx = 4 + travel * t;
              // Anchor the squash to the leading edge so it presses into the
              // end it's arriving at.
              final anchor = _c.velocity >= 0 ? Alignment.centerRight
                                              : Alignment.centerLeft;
              return Opacity(
                opacity: enabled ? 1 : 0.5,
                child: Stack(
                  children: [
                    Container(
                      width: _w,
                      height: _h,
                      decoration: BoxDecoration(
                        color: trackOn,
                        borderRadius: BorderRadius.circular(_h / 2),
                        border: Border.all(
                          color: on > 0.5
                              ? Colors.transparent
                              : scheme.outlineVariant,
                        ),
                      ),
                    ),
                    Positioned(
                      left: dx,
                      top: (_h - _thumb) / 2,
                      child: Transform.scale(
                        scaleX: 1 + stretch,
                        scaleY: 1 - stretch * 0.75,
                        alignment: anchor,
                        child: Container(
                          width: _thumb,
                          height: _thumb,
                          decoration: BoxDecoration(
                            color: thumbColor,
                            borderRadius: BorderRadius.circular(_thumb / 2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A segmented picker with a single sliding pill instead of per-segment
/// outlines. Material's SegmentedButton gives every option its own border and
/// its own padding, so four options stop fitting on a phone; here the segments
/// share one track, split it evenly and never wrap. The pill springs between
/// them and stretches along the way — the further it travels, the longer it
/// gets, snapping back once it lands.
class JellySegmented<T> extends StatefulWidget {
  const JellySegmented({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelect,
    this.enabled = true,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelect;
  final bool enabled;

  @override
  State<JellySegmented<T>> createState() => _JellySegmentedState<T>();
}

class _JellySegmentedState<T> extends State<JellySegmented<T>>
    with SingleTickerProviderStateMixin {
  static const _height = 46.0;
  static const _pad = 4.0;

  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
    value: widget.values.indexOf(widget.selected).toDouble(),
  );
  // Enough overshoot to feel alive, not enough to look loose.
  static const _slide = SpringDescription(mass: 1, stiffness: 240, damping: 19);

  @override
  void didUpdateWidget(JellySegmented<T> old) {
    super.didUpdateWidget(old);
    final target = widget.values.indexOf(widget.selected).toDouble();
    if (target >= 0 && target != old.values.indexOf(old.selected).toDouble()) {
      _c.animateWith(SpringSimulation(_slide, _c.value, target, _c.velocity));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = widget.values.length;
    return Opacity(
      opacity: widget.enabled ? 1 : 0.5,
      child: IgnorePointer(
        ignoring: !widget.enabled,
        child: LayoutBuilder(
          builder: (context, box) {
            final slot = (box.maxWidth - _pad * 2) / n;
            return SizedBox(
              height: _height,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(_height / 2),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: _c,
                    builder: (context, _) {
                      // Speed → length. The pill keeps its centre, so it grows
                      // out of both ends rather than lurching forward.
                      final stretch =
                          (_c.velocity.abs() / 26).clamp(0.0, 0.38);
                      final w = slot * (1 + stretch);
                      final centre = _pad + slot * (_c.value + 0.5);
                      return Positioned(
                        left: centre - w / 2,
                        top: _pad,
                        width: w,
                        height: _height - _pad * 2,
                        child: Container(
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius:
                                BorderRadius.circular((_height - _pad * 2) / 2),
                          ),
                        ),
                      );
                    },
                  ),
                  Row(
                    children: [
                      for (final v in widget.values)
                        Expanded(
                          child: JellyTap(
                            pressScale: 0.9,
                            onTap: () => widget.onSelect(v),
                            child: SizedBox(
                              height: _height,
                              child: Center(
                                child: AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 180),
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: v == widget.selected
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                    color: v == widget.selected
                                        ? scheme.onPrimary
                                        : scheme.onSurfaceVariant,
                                  ),
                                  child: Text(
                                    widget.labelOf(v),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A [ListTile] row whose trailing control is a [JellySwitch] and whose whole
/// row reacts to the press — the drop-in for SwitchListTile.
///
/// The switch moves the instant it's tapped and STAYS there: the reported
/// [value] only catches up once the root command behind it has run, and a
/// round trip through `su` is slow enough that waiting for it made the toggle
/// feel broken (no animation, then a jump). So the tile shows its own
/// optimistic position until reality agrees, and the work is kicked off a frame
/// later so the spring is already moving before anything can block. Nothing
/// here disables the row while busy — that was the other half of the jank, the
/// control going dead and its leading icon swapping mid-press.
class JellySwitchTile extends StatefulWidget {
  const JellySwitchTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.secondary,
  });

  final String title;
  final String subtitle;
  final bool value;

  /// Awaited before the tile gives up its optimistic position — an action that
  /// ends in a declined confirmation changes nothing, so there would be no
  /// state update to reconcile against and the switch would stay stuck.
  final Future<void> Function(bool)? onChanged;
  final Widget? secondary;

  @override
  State<JellySwitchTile> createState() => _JellySwitchTileState();
}

class _JellySwitchTileState extends State<JellySwitchTile> {
  bool? _optimistic;
  bool _inFlight = false;

  @override
  void didUpdateWidget(JellySwitchTile old) {
    super.didUpdateWidget(old);
    // Reality caught up (or came back different, e.g. the action failed) —
    // hand control back to the reported value.
    if (_optimistic != null && widget.value != old.value) {
      _optimistic = null;
    }
  }

  Future<void> _toggle() async {
    final onChanged = widget.onChanged;
    if (onChanged == null || _inFlight) return;
    final target = !(_optimistic ?? widget.value);
    setState(() {
      _optimistic = target;
      _inFlight = true;
    });
    try {
      // Let the switch's spring get on screen before the root call starts.
      await Future<void>.delayed(const Duration(milliseconds: 90));
      if (!mounted) return;
      await onChanged(target);
    } finally {
      if (mounted) {
        setState(() {
          _optimistic = null;
          _inFlight = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _optimistic ?? widget.value;
    final enabled = widget.onChanged != null;
    return Jelly(
      enabled: enabled,
      pressScale: 0.978,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: widget.secondary,
        title: Text(widget.title),
        subtitle: Text(widget.subtitle),
        trailing: JellySwitch(
          value: shown,
          onChanged: enabled ? (_) => _toggle() : null,
        ),
        onTap: enabled ? _toggle : null,
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
