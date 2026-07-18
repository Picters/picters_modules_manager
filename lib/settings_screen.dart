import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'widgets.dart';

/// App settings, reached from the gear in the Overview app bar. Home for the
/// boot-time auto-load toggle (moved off the Overview screen so that screen
/// stays a pure status dashboard).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _setBootLoad(bool value) async {
    HapticFeedback.selectionClick();
    await controller.setBootLoadEnabled(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              const SectionHeader(icon: Icons.flash_on, label: 'Startup'),
              const SizedBox(height: 12),
              _BootLoadCard(
                enabled: controller.bootLoadEnabled,
                busy: controller.bootLoadBusy,
                onChanged: _setBootLoad,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Toggles whether the boot-time loader (service.sh) auto-loads every staged
/// non-Wi-Fi module on Android startup. Off by default — nothing loads at boot
/// until the user opts in here.
class _BootLoadCard extends StatelessWidget {
  const _BootLoadCard({
    required this.enabled,
    required this.busy,
    required this.onChanged,
  });

  final bool enabled;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.outlined(
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary: busy
            ? SizedBox(
                width: 24,
                height: 24,
                child: MorphingPolygon(size: 24, color: scheme.primary),
              )
            : Icon(Icons.flash_on, color: scheme.onSurfaceVariant),
        title: const Text('Load modules on boot'),
        subtitle: const Text(
          'Auto-loads every module except Wi-Fi when the device starts.',
        ),
        value: enabled,
        onChanged: busy ? null : onChanged,
      ),
    );
  }
}
