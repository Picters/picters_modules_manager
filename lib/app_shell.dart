import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'module_repository.dart';
import 'modules_screen.dart';
import 'overview_screen.dart';
import 'theme.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final AppController _controller = AppController(ModuleRepository());
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.black,
      extendBody: true,
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          switch (_controller.rootStatus) {
            case RootStatus.checking:
              return const _CenterGlyph(
                icon: Icons.hourglass_empty,
                title: 'Checking root access…',
                spinner: true,
              );
            case RootStatus.denied:
              return const _RootDenied();
            case RootStatus.granted:
              return SafeArea(
                bottom: false,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  child: _tab == 0
                      ? OverviewScreen(
                          key: const ValueKey('overview'),
                          controller: _controller,
                        )
                      : ModulesScreen(
                          key: const ValueKey('modules'),
                          controller: _controller,
                        ),
                ),
              );
          }
        },
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          if (_controller.rootStatus != RootStatus.granted) {
            return const SizedBox.shrink();
          }
          return _FrostedNavBar(
            index: _tab,
            onChanged: (i) => setState(() => _tab = i),
          );
        },
      ),
    );
  }
}

class _FrostedNavBar extends StatelessWidget {
  const _FrostedNavBar({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceGlass,
            border: Border(top: BorderSide(color: AppColors.outline)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + 8,
            top: 10,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _NavItem(
                icon: Icons.shield_moon_outlined,
                activeIcon: Icons.shield_moon,
                label: 'Overview',
                selected: index == 0,
                onTap: () => onChanged(0),
              ),
              _NavItem(
                icon: Icons.tune_outlined,
                activeIcon: Icons.tune,
                label: 'Modules',
                selected: index == 1,
                onTap: () => onChanged(1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.white : AppColors.gray;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: selected ? 1.0 : 0.9,
              duration: const Duration(milliseconds: 200),
              child: Icon(selected ? activeIcon : icon, color: color, size: 26),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RootDenied extends StatelessWidget {
  const _RootDenied();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 56, color: AppColors.red),
            const SizedBox(height: 20),
            const Text(
              'Root required',
              style: TextStyle(
                color: AppColors.white,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Grant root to Picters Kernel Manager in your KernelSU or '
              'Magisk manager app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.gray, fontSize: 15, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterGlyph extends StatelessWidget {
  const _CenterGlyph({
    required this.icon,
    required this.title,
    this.spinner = false,
  });

  final IconData icon;
  final String title;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinner)
            const CircularProgressIndicator(color: AppColors.white, strokeWidth: 2.5)
          else
            Icon(icon, color: AppColors.gray, size: 48),
          const SizedBox(height: 18),
          Text(title, style: const TextStyle(color: AppColors.gray, fontSize: 15)),
        ],
      ),
    );
  }
}
