import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// A soft pulsing dot — the "live / active" cue on the NetHunter hero card.
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
    return FadeTransition(
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

/// Fades + slides a child in once, the first time it's mounted. Reused for
/// every top-level card/section so the screen feels like it's building
/// itself in rather than popping into place — plays again whenever the
/// widget gets a fresh element (e.g. a list item shifting position), which
/// is the desired "appearing" effect for newly-plugged adapters too.
class FadeInSlide extends StatefulWidget {
  const FadeInSlide({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  State<FadeInSlide> createState() => _FadeInSlideState();
}

class _FadeInSlideState extends State<FadeInSlide> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  late final Animation<double> _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
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
