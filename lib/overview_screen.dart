import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'module_info.dart';
import 'theme.dart';
import 'usb_devices.dart';
import 'widgets.dart';

class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _setWifi(BuildContext context, WifiMode target) async {
    HapticFeedback.selectionClick();
    // Switching to Inject tears the stock vendor Wi-Fi down, and on this
    // hardware it can't come back without a cold reboot — so make the user
    // confirm that one-way trip before running it.
    if (target == WifiMode.inject) {
      final ok = await confirmAction(
        context,
        title: 'Switch to Inject mode?',
        message:
            'This unloads the stock Wi-Fi stack and loads the injection '
            'stack for monitor mode and packet injection. Stock Wi-Fi can only '
            'be restored by rebooting the device.',
        confirmLabel: 'Switch',
      );
      if (!ok || !context.mounted) return;
    }
    final err = await controller.setWifiMode(target);
    if (!context.mounted) return;
    // Selecting Stock never runs a switch — it just flips the hero to the
    // honest "Reboot needed" card (stock can't return without a cold boot), so
    // there's nothing to announce here.
    if (target == WifiMode.stock) return;
    if (err != null) {
      showError(context, err);
      if (controller.lastWifiSwitchDiagnostics != null) {
        showDiagnosticsDialog(context, controller.lastWifiSwitchDiagnostics!);
      }
    } else {
      showInfo(context, 'Inject mode enabled.');
    }
  }

  Future<void> _reboot(BuildContext context) async {
    final ok = await confirmAction(
      context,
      title: 'Reboot now?',
      message:
          'Stock Wi-Fi can only be restored by a full reboot. The device '
          'will restart immediately.',
      confirmLabel: 'Reboot',
      destructive: true,
    );
    if (ok) {
      HapticFeedback.mediumImpact();
      controller.rebootDevice();
    }
  }

  Future<void> _loadAdapter(BuildContext context, DetectedAdapter a) async {
    HapticFeedback.selectionClick();
    final err = await controller.loadAdapter(a);
    if (!context.mounted) return;
    if (err != null) showError(context, err);
  }

  Future<void> _setBootLoad(BuildContext context, bool value) async {
    HapticFeedback.selectionClick();
    await controller.setBootLoadEnabled(value);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = controller.state;
        final adapters = state.adapters.where((a) => a.recognized).toList();

        return PolygonScrollView(
          onRefresh: controller.refresh,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          children: [
            _WifiHeroCard(
              mode: controller.optimisticWifiMode ?? state.wifiMode,
              needsReboot: controller.lastSwitchNeedsReboot,
              busy: controller.wifiBusy,
              onSelect: (m) => _setWifi(context, m),
              onReboot: () => _reboot(context),
            ),
            const SizedBox(height: 26),
            SectionHeader(
              icon: Icons.usb,
              label: 'Plugged-in adapters',
              trailing: adapters.isEmpty ? null : '${adapters.length}',
            ),
            const SizedBox(height: 12),
            AnimatedSection(
              child: adapters.isEmpty
                  ? const _EmptyAdapters(key: ValueKey('empty'))
                  : Card.outlined(
                      key: ValueKey('list-${adapters.length}'),
                      child: Column(
                        children: [
                          for (var i = 0; i < adapters.length; i++)
                            UnfoldIn(
                              delay: Duration(milliseconds: i * 95),
                              child: Column(
                                children: [
                                  if (i > 0) const CardDivider(),
                                  _AdapterRow(
                                    adapter: adapters[i],
                                    state: state,
                                    busy: controller.moduleBusy.contains(
                                      adapters[i].match!.driver,
                                    ),
                                    onLoad: () =>
                                        _loadAdapter(context, adapters[i]),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 26),
            SectionHeader(icon: Icons.settings_outlined, label: 'Startup'),
            const SizedBox(height: 12),
            RepaintBoundary(
              child: _BootLoadCard(
                enabled: controller.bootLoadEnabled,
                busy: controller.bootLoadBusy,
                onChanged: (v) => _setBootLoad(context, v),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Toggles whether the boot-time loader (service.sh) auto-loads every staged
/// non-Wi-Fi module on Android startup. Off by default — nothing loads at
/// boot until the user opts in here.
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

class _WifiHeroCard extends StatelessWidget {
  const _WifiHeroCard({
    required this.mode,
    required this.needsReboot,
    required this.busy,
    required this.onSelect,
    required this.onReboot,
  });

  final WifiMode mode;
  final bool needsReboot;
  final bool busy;
  final ValueChanged<WifiMode> onSelect;
  final VoidCallback onReboot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inj = mode == WifiMode.inject;

    final Color background;
    final Color borderColor;
    if (needsReboot) {
      background = scheme.surfaceContainerHighest;
      borderColor = Colors.transparent;
    } else {
      background = inj
          ? Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.09),
              scheme.surfaceContainerHigh,
            )
          : scheme.surfaceContainerHigh;
      borderColor = inj
          ? scheme.primary.withValues(alpha: 0.45)
          : Colors.transparent;
    }

    // The shell colour/border animate (AnimatedContainer), and the whole inner
    // block cross-fades + resizes between the status and reboot states, so
    // flipping Stock/Inject/Reboot glides instead of snapping.
    return RepaintBoundary(
      child: _HeroShell(
        background: background,
        border: Border.all(color: borderColor, width: 1.5),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 340),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 340),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.06),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            layoutBuilder: (currentChild, previousChildren) => Stack(
              alignment: Alignment.topCenter,
              children: [...previousChildren, ?currentChild],
            ),
            child: KeyedSubtree(
              key: ValueKey(needsReboot ? 'reboot' : 'status'),
              child: needsReboot
                  ? _rebootContent(context)
                  : _statusContent(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rebootContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _HeroIcon(
              icon: Icons.restart_alt,
              bg: scheme.surfaceContainerHigh,
              fg: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reboot needed',
                    style: textTheme.titleMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Reboot to restore stock Wi-Fi.',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onReboot,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reboot now'),
          ),
        ),
      ],
    );
  }

  Widget _statusContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final inj = mode == WifiMode.inject;
    final (icon, title, subtitle) = switch (mode) {
      WifiMode.stock => (Icons.wifi, 'Stock Wi-Fi', 'Built-in Wi-Fi is on.'),
      WifiMode.inject => (
        Icons.security,
        'Inject Wi-Fi',
        'Injection stack loaded.',
      ),
      WifiMode.off => (Icons.wifi_off, 'Wi-Fi is off', 'No stack loaded.'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _HeroIcon(
              icon: icon,
              bg: inj ? scheme.primary : scheme.surfaceContainerHighest,
              fg: inj ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.06, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...previousChildren, ?currentChild],
                ),
                child: Column(
                  key: ValueKey(mode),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: textTheme.titleMedium?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (busy) ...[
                          const SizedBox(width: 10),
                          MorphingPolygon(size: 17, color: scheme.primary),
                        ] else if (inj) ...[
                          const SizedBox(width: 10),
                          PulsingDot(color: scheme.primary, size: 8),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _WifiSegmented(mode: mode, onSelect: onSelect),
      ],
    );
  }
}

/// The two-way Wi-Fi switch: a full-width segmented toggle between the stock
/// vendor stack and our injection stack. `off` shows neither segment selected.
class _WifiSegmented extends StatelessWidget {
  const _WifiSegmented({required this.mode, required this.onSelect});

  final WifiMode mode;
  final ValueChanged<WifiMode> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<WifiMode>(
        segments: const [
          ButtonSegment(
            value: WifiMode.stock,
            label: Text('Stock'),
            icon: Icon(Icons.wifi),
          ),
          ButtonSegment(
            value: WifiMode.inject,
            label: Text('Inject'),
            icon: Icon(Icons.security),
          ),
        ],
        selected: mode == WifiMode.off ? <WifiMode>{} : {mode},
        emptySelectionAllowed: true,
        showSelectedIcon: false,
        onSelectionChanged: (selection) {
          if (selection.isEmpty) return;
          final target = selection.first;
          if (target != mode) onSelect(target);
        },
      ),
    );
  }
}

/// The rounded, padded shell every hero-card variant shares. An
/// [AnimatedContainer] so the background and accent border glide when the
/// Wi-Fi mode changes.
class _HeroShell extends StatelessWidget {
  const _HeroShell({
    required this.child,
    required this.background,
    this.border,
  });

  final Widget child;
  final Color background;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: background,
        border: border,
        borderRadius: BorderRadius.circular(Corners.hero),
      ),
      padding: const EdgeInsets.all(20),
      child: child,
    );
  }
}

class _HeroIcon extends StatelessWidget {
  const _HeroIcon({required this.icon, required this.bg, required this.fg});

  final IconData icon;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
      width: 54,
      height: 54,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: (child, animation) => ScaleTransition(
          scale: animation,
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: Icon(icon, key: ValueKey(icon), color: fg, size: 27),
      ),
    );
  }
}

class _AdapterRow extends StatelessWidget {
  const _AdapterRow({
    required this.adapter,
    required this.state,
    required this.busy,
    required this.onLoad,
  });

  final DetectedAdapter adapter;
  final SystemState state;
  final bool busy;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final match = adapter.match!;
    final loaded = state.modules.any((m) => m.name == match.driver && m.loaded);

    final Widget trailing;
    if (busy) {
      trailing = MorphingPolygon(
        key: const ValueKey('busy'),
        size: 32,
        color: scheme.primary,
      );
    } else if (loaded) {
      trailing = Icon(
        Icons.check_circle,
        key: const ValueKey('loaded'),
        color: scheme.primary,
        size: 32,
      );
    } else {
      trailing = FilledButton.tonal(
        key: const ValueKey('idle'),
        onPressed: onLoad,
        child: const Text('Load'),
      );
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHighest,
        child: Icon(
          Icons.wifi_tethering,
          color: scheme.onSurfaceVariant,
          size: 20,
        ),
      ),
      title: Text(adapter.device.displayName, overflow: TextOverflow.ellipsis),
      subtitle: Text('${adapter.device.idPair} · ${match.driver}'),
      // Fixed-width slot with everything CENTRED: the spinner and checkmark
      // land dead-centre on the "Load" button's footprint and stay there —
      // the slot never resizes, and the switcher's default centre-alignment
      // keeps the outgoing/incoming children concentric, so nothing shifts.
      trailing: SizedBox(
        width: 84,
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.85, end: 1.0).animate(animation),
                child: child,
              ),
            ),
            child: trailing,
          ),
        ),
      ),
    );
  }
}

class _EmptyAdapters extends StatelessWidget {
  const _EmptyAdapters({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        child: Row(
          children: [
            Icon(Icons.usb_off, color: scheme.onSurfaceVariant, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'No supported adapter plugged in.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
