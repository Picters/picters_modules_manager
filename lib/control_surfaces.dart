import 'package:flutter/material.dart';

import 'widgets.dart';

/// The same themed card used by Overview and Modules.
class ControlPanel extends StatelessWidget {
  const ControlPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Card.outlined(
    child: Padding(padding: padding, child: child),
  );
}

/// Matches the category icons in the module library.
class ControlIcon extends StatelessWidget {
  const ControlIcon(this.icon, {super.key, this.active = false});
  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Icon(
        icon,
        size: 23,
        color: active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
    );
  }
}

class ControlHeading extends StatelessWidget {
  const ControlHeading(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.25,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 5),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: 12), trailing!],
    ],
  );
}

class ValueBadge extends StatelessWidget {
  const ValueBadge(this.value, {super.key, this.active = false});
  final String value;
  final bool active;
  @override
  Widget build(BuildContext context) =>
      ReelPill(text: value, highlight: active);
}

class ReadoutTile extends StatelessWidget {
  const ReadoutTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.detail,
  });
  final String label, value;
  final IconData icon;
  final String? detail;
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ControlPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: s.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12, color: s.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.8,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 5),
            Text(
              detail!,
              style: TextStyle(fontSize: 11, color: s.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class ControlSwitch extends StatelessWidget {
  const ControlSwitch({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.icon = Icons.tune,
  });
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      ControlIcon(icon, active: value),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      Switch(value: value, onChanged: onChanged),
    ],
  );
}
