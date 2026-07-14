import 'package:flutter/material.dart';

import 'theme.dart';

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
