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

  Future<void> _toggleWifi(BuildContext context, bool toNetHunter) async {
    HapticFeedback.selectionClick();
    final err = await controller.setWifiMode(
      toNetHunter ? WifiMode.nethunter : WifiMode.stock,
    );
    if (!context.mounted) return;
    if (err != null) {
      // A failed stock restore is unrecoverable without a reboot, so it just
      // flips the hero card to its "Reboot needed" state — no error banner,
      // no dmesg dialog. Only the (recoverable) NetHunter-load failure still
      // surfaces its diagnostics.
      if (!controller.lastSwitchNeedsReboot) {
        showError(context, err);
        if (controller.lastWifiSwitchDiagnostics != null) {
          showDiagnosticsDialog(context, controller.lastWifiSwitchDiagnostics!);
        }
      }
    } else {
      showInfo(
        context,
        toNetHunter ? 'NetHunter Wi-Fi enabled.' : 'Stock Wi-Fi restored.',
      );
    }
  }

  Future<void> _reboot(BuildContext context) async {
    final ok = await confirmAction(
      context,
      title: 'Reboot now?',
      message: 'Stock Wi-Fi can only be restored by a full reboot. The device '
          'will restart immediately.',
      confirmLabel: 'Reboot',
      destructive: true,
    );
    if (ok) controller.rebootDevice();
  }

  Future<void> _loadAdapter(BuildContext context, DetectedAdapter a) async {
    HapticFeedback.selectionClick();
    final err = await controller.loadAdapter(a);
    if (!context.mounted) return;
    if (err != null) {
      showError(context, err);
      if (controller.lastModuleDiagnostics != null) {
        showDiagnosticsDialog(context, controller.lastModuleDiagnostics!);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = controller.state;
        final recognized = state.adapters.where((a) => a.recognized).toList();
        final unknown = state.adapters.where((a) => !a.recognized).toList();

        return RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              FadeInSlide(
                child: _WifiHeroCard(
                  mode: controller.optimisticWifiMode ?? state.wifiMode,
                  needsReboot: controller.lastSwitchNeedsReboot,
                  busy: controller.wifiBusy,
                  onChanged: (v) => _toggleWifi(context, v),
                  onReboot: () => _reboot(context),
                ),
              ),
              const SizedBox(height: 24),
              FadeInSlide(
                delay: const Duration(milliseconds: 80),
                child: SectionHeader(
                  icon: Icons.usb,
                  label: 'Plugged-in adapters',
                  trailing: recognized.isEmpty ? null : '${recognized.length}',
                ),
              ),
              const SizedBox(height: 12),
              FadeInSlide(
                delay: const Duration(milliseconds: 140),
                child: AnimatedSection(
                  child: recognized.isEmpty
                      ? _EmptyAdapters(key: const ValueKey('empty'), unknownCount: unknown.length)
                      : Card.outlined(
                          key: ValueKey('list-${recognized.length}'),
                          child: Column(
                            children: [
                              for (var i = 0; i < recognized.length; i++) ...[
                                if (i > 0) const CardDivider(),
                                FadeInSlide(
                                  delay: Duration(milliseconds: i * 60),
                                  child: _AdapterRow(
                                    adapter: recognized[i],
                                    state: state,
                                    busy: controller.moduleBusy
                                        .contains(recognized[i].match!.driver),
                                    onLoad: () => _loadAdapter(context, recognized[i]),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
              ),
              if (unknown.isNotEmpty) ...[
                const SizedBox(height: 12),
                FadeInSlide(
                  delay: const Duration(milliseconds: 180),
                  child: _UnknownDevices(devices: unknown),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _WifiHeroCard extends StatelessWidget {
  const _WifiHeroCard({
    required this.mode,
    required this.needsReboot,
    required this.busy,
    required this.onChanged,
    required this.onReboot,
  });

  final WifiMode mode;
  final bool needsReboot;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final VoidCallback onReboot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (needsReboot) {
      return _HeroShell(
        background: scheme.surfaceContainerHighest,
        child: Row(
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
                    style: textTheme.titleMedium
                        ?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    "Stock Wi-Fi won't come back without one.",
                    style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: onReboot, child: const Text('Reboot')),
          ],
        ),
      );
    }

    final nh = mode == WifiMode.nethunter;
    final (icon, title, subtitle, badge) = switch (mode) {
      WifiMode.stock => (
          Icons.wifi,
          'Stock Wi-Fi',
          "The phone's built-in Wi-Fi is running.",
          'STOCK',
        ),
      WifiMode.nethunter => (
          Icons.security,
          'NetHunter Wi-Fi',
          'Our kernel cfg80211 is loaded — injection ready.',
          'ACTIVE',
        ),
      WifiMode.off => (
          Icons.wifi_off,
          'Wi-Fi is inactive',
          'Neither stock nor our stack is loaded.',
          'OFF',
        ),
    };
    final fg = nh ? scheme.onPrimaryContainer : scheme.onSurface;
    final fgMuted =
        nh ? scheme.onPrimaryContainer.withValues(alpha: 0.75) : scheme.onSurfaceVariant;

    return _HeroShell(
      gradient: nh
          ? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.primaryContainer,
                Color.alphaBlend(
                    scheme.primary.withValues(alpha: 0.28), scheme.primaryContainer),
              ],
            )
          : null,
      background: nh ? null : scheme.surfaceContainerHigh,
      child: Row(
        children: [
          _HeroIcon(
            icon: icon,
            bg: nh ? scheme.primary : scheme.surfaceContainerHighest,
            fg: nh ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Column(
                key: ValueKey(mode),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: textTheme.titleMedium
                              ?.copyWith(color: fg, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _ModeBadge(text: badge, active: nh),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: textTheme.bodySmall?.copyWith(color: fgMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // A tiny spinner rides alongside the switch while the round-trip is
          // in flight; the switch itself already flipped optimistically.
          SizedBox(
            width: 24,
            child: busy
                ? Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: nh ? scheme.onPrimaryContainer : scheme.primary,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 4),
          Switch(value: nh, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// The rounded, padded shell every hero-card variant shares — takes either a
/// flat [background] colour or a [gradient].
class _HeroShell extends StatelessWidget {
  const _HeroShell({required this.child, this.background, this.gradient});

  final Widget child;
  final Color? background;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: background,
        gradient: gradient,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(18),
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
    return Container(
      width: 50,
      height: 50,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon, color: fg, size: 26),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.text, required this.active});
  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.only(left: active ? 7 : 9, right: 9, top: 3, bottom: 3),
      decoration: BoxDecoration(
        color: active ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active) ...[
            PulsingDot(color: scheme.onPrimary, size: 7),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
          ),
        ],
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

    Widget trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    } else if (loaded) {
      trailing = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt, color: scheme.onPrimaryContainer, size: 16),
            const SizedBox(width: 3),
            Text(
              'active',
              style: TextStyle(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      );
    } else {
      trailing = FilledButton.tonal(onPressed: onLoad, child: const Text('Load'));
    }

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHighest,
        child: Icon(Icons.wifi_tethering, color: scheme.onSurfaceVariant, size: 20),
      ),
      title: Text(adapter.device.displayName, overflow: TextOverflow.ellipsis),
      subtitle: Text('${adapter.device.idPair} · ${match.driver}'),
      trailing: trailing,
    );
  }
}

class _EmptyAdapters extends StatelessWidget {
  const _EmptyAdapters({super.key, required this.unknownCount});

  final int unknownCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
        child: Row(
          children: [
            Icon(Icons.usb_off, color: scheme.onSurfaceVariant, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                unknownCount > 0
                    ? 'No supported Wi-Fi adapter detected. See the unrecognized '
                        'device${unknownCount == 1 ? '' : 's'} below.'
                    : "Plug in a USB Wi-Fi adapter — it'll show up here.",
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Off-list USB devices — collapsed by default, so a pentester with an adapter
/// whose VID:PID isn't in our table can still read it off and pick a driver by
/// hand on the Modules tab, instead of it silently vanishing.
class _UnknownDevices extends StatelessWidget {
  const _UnknownDevices({required this.devices});

  final List<DetectedAdapter> devices;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.outlined(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(Icons.help_outline, color: scheme.onSurfaceVariant),
          title: Text(
            '${devices.length} unrecognized USB device${devices.length == 1 ? '' : 's'}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: const Text('No matching driver in the built-in table'),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            for (final d in devices)
              ListTile(
                dense: true,
                leading: Icon(Icons.usb, size: 20, color: scheme.onSurfaceVariant),
                title: Text(d.device.displayName, overflow: TextOverflow.ellipsis),
                trailing: SelectableText(
                  d.device.idPair,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
