import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// A copyable dialog for a captured dmesg tail — shared by any failure path
/// that surfaces [ModuleRepository]'s diagnostics (Wi-Fi mode switch, plain
/// module toggle) instead of just an opaque "didn't work" message.
void showDiagnosticsDialog(BuildContext context, String dmesgTail) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Diagnostics', style: TextStyle(color: AppColors.white)),
      content: SingleChildScrollView(
        child: SelectableText(
          dmesgTail.isEmpty ? '(no matching dmesg lines)' : dmesgTail,
          style: const TextStyle(
            color: AppColors.gray,
            fontSize: 12.5,
            fontFamily: 'monospace',
            height: 1.4,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: dmesgTail));
            Navigator.of(context).pop();
          },
          child: const Text('Copy', style: TextStyle(color: AppColors.white)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close', style: TextStyle(color: AppColors.gray)),
        ),
      ],
    ),
  );
}

const TextStyle sectionLabelStyle = TextStyle(
  color: AppColors.gray,
  fontSize: 14,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.2,
);

class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        if (subtitle != null)
          Text(
            subtitle!.toUpperCase(),
            style: const TextStyle(
              color: AppColors.gray,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
            ),
          ),
        const SizedBox(height: 4),
        Text(
          title,
          style: const TextStyle(
            color: AppColors.white,
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.8,
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }
}

/// A rounded, subtly bordered dark card — the one container style used app-wide.
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class CardDivider extends StatelessWidget {
  const CardDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      thickness: 1,
      color: AppColors.outline,
      indent: 18,
      endIndent: 18,
    );
  }
}
