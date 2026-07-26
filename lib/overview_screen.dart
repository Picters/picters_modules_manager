import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'adapter_panel.dart';
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
    // Tapping Inject while the reboot fallback is armed just cancels it — the
    // device is still in Inject mode, so nothing needs to run.
    if (target == WifiMode.inject && controller.lastSwitchNeedsReboot) {
      controller.cancelStockReboot();
      return;
    }
    // Both directions switch live in one tap now: Inject unloads the vendor
    // stack, Stock reloads it (the cnss2/PCIe link survives, so no reboot).
    final err = await controller.setWifiMode(target);
    if (!context.mounted) return;
    if (err != null) {
      // A stock switch that couldn't come back live arms the reboot fallback —
      // surface that as a clear "reboot needed" prompt rather than a raw error.
      if (controller.lastSwitchNeedsReboot) {
        await _showRebootNeededDialog(context);
      } else {
        showError(context, err);
        if (controller.lastWifiSwitchDiagnostics != null) {
          showDiagnosticsDialog(context, controller.lastWifiSwitchDiagnostics!);
        }
      }
    } else {
      showInfo(
        context,
        target == WifiMode.stock ? 'Stock Wi-Fi restored.' : 'Inject mode enabled.',
      );
    }
  }

  /// Shown when a live return to Stock failed: the injection stack is still up,
  /// and only a reboot brings the built-in Wi-Fi back. Offers Reboot now, Later
  /// (the hero card stays armed for reboot), or the raw dmesg via Details.
  Future<void> _showRebootNeededDialog(BuildContext context) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.restart_alt),
        title: const Text('Reboot needed'),
        content: const Text(
          "Stock Wi-Fi couldn't be restored without a restart. Injection stays "
          'active until you reboot — reboot now to bring the built-in Wi-Fi back.',
        ),
        actions: [
          if (controller.lastWifiSwitchDiagnostics != null)
            Jelly(child: TextButton(
              onPressed: () {
                Navigator.of(ctx).pop(false);
                showDiagnosticsDialog(
                    context, controller.lastWifiSwitchDiagnostics!);
              },
              child: const Text('Details'),
            )),
          Jelly(child: TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Later'),
          )),
          Jelly(child: FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Reboot'),
          )),
        ],
      ),
    );
    if (proceed == true) {
      HapticFeedback.mediumImpact();
      controller.rebootDevice();
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

  Future<void> _reconfigure(BuildContext context) async {
    HapticFeedback.selectionClick();
    final ifaces = controller.adapterInterfaces;
    WifiInterface? chosen;
    if (ifaces.length > 1) {
      // More than one adapter interface is live — let the user pick which one
      // to hand to Android's Wi-Fi framework.
      chosen = await showInterfacePicker(context, interfaces: ifaces);
      if (chosen == null || !context.mounted) return; // cancelled
    } else if (ifaces.length == 1) {
      chosen = ifaces.first;
    }
    // chosen == null with no interfaces falls back to the driver-based path,
    // which returns a friendly "nothing loaded" error.
    final err = await controller.reconfigureAdapter(iface: chosen);
    if (!context.mounted) return;
    if (err != null) {
      showError(context, err);
    } else {
      showInfo(context, 'Reconfigured — check Settings › Wi-Fi to connect.');
    }
  }

  Future<void> _loadAdapter(BuildContext context, DetectedAdapter a) async {
    HapticFeedback.selectionClick();
    final err = await controller.loadAdapter(a);
    if (!context.mounted) return;
    if (err != null) showError(context, err);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = controller.state;
        // Every plugged-in device, not just the Wi-Fi adapters we recognise —
        // minus USB hubs (the phone's own root hubs), which are just noise.
        // Recognised Wi-Fi adapters (the actionable ones) float to the top.
        final devices = state.adapters
            .where((a) => classifyUsb(a) != UsbKind.hub)
            .toList()
          ..sort((a, b) {
            if (a.recognized != b.recognized) return a.recognized ? -1 : 1;
            return a.device.displayName
                .toLowerCase()
                .compareTo(b.device.displayName.toLowerCase());
          });

        return PolygonScrollView(
          onRefresh: controller.refresh,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          children: [
            _WifiHeroCard(
              mode: controller.optimisticWifiMode ?? state.wifiMode,
              needsReboot: controller.lastSwitchNeedsReboot,
              busy: controller.wifiBusy,
              reconfiguring: controller.reconfiguring,
              canReconfigure: controller.adapterInterfaces.isNotEmpty,
              onSelect: (m) => _setWifi(context, m),
              onReboot: () => _reboot(context),
              onReconfigure: () => _reconfigure(context),
            ),
            const SizedBox(height: 26),
            SectionHeader(
              icon: Icons.usb,
              label: 'USB devices',
              trailing: devices.isEmpty ? null : '${devices.length}',
            ),
            const SizedBox(height: 12),
            AnimatedSection(
              // AnimatedSection's AnimatedSize is the ONE height animator; rows
              // only fade/slide in (RowReveal) so no nested size animator fights
              // it. Adding or unplugging a device just glides the card height.
              child: devices.isEmpty
                  ? const _EmptyAdapters(key: ValueKey('empty'))
                  : Card.outlined(
                      key: const ValueKey('list'),
                      child: Column(
                        children: [
                          for (var i = 0; i < devices.length; i++)
                            RowReveal(
                              key: ValueKey(
                                'dev-${devices[i].device.idPair}-'
                                '${devices[i].device.product}-'
                                '${devices[i].device.manufacturer}',
                              ),
                              delay: Duration(milliseconds: i * 45),
                              child: Column(
                                children: [
                                  if (i > 0) const CardDivider(),
                                  // Only a recognised Wi-Fi chipset unfolds its
                                  // controls — a loaded non-Wi-Fi USB device
                                  // (network dongle, storage, etc.) has nothing
                                  // to configure, so it just reads "Loaded"
                                  // with no tap target.
                                  _AdapterRow(
                                    adapter: devices[i],
                                    state: state,
                                    iface: devices[i].recognized
                                        ? matchingIface(
                                            devices[i], state.interfaces)
                                        : null,
                                    controller: controller,
                                    busy: devices[i].recognized &&
                                        controller.moduleBusy.contains(
                                          devices[i].match!.driver,
                                        ),
                                    onLoad: () =>
                                        _loadAdapter(context, devices[i]),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
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
    required this.reconfiguring,
    required this.canReconfigure,
    required this.onSelect,
    required this.onReboot,
    required this.onReconfigure,
  });

  final WifiMode mode;
  final bool needsReboot;
  final bool busy;
  final bool reconfiguring;
  final bool canReconfigure;
  final ValueChanged<WifiMode> onSelect;
  final VoidCallback onReboot;
  final VoidCallback onReconfigure;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inj = mode == WifiMode.inject;

    final Color background;
    final Color borderColor;
    if (needsReboot) {
      // A caution tint so the armed-reboot state stands apart from the neutral
      // icon tile and the segmented track (all three used to share one tone).
      background = Color.alphaBlend(
        scheme.error.withValues(alpha: 0.10),
        scheme.surfaceContainerHigh,
      );
      borderColor = scheme.error.withValues(alpha: 0.45);
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

    // The shell colour/border animate (AnimatedContainer). The card keeps ONE
    // layout at all times — icon row + the sliding segmented switch — so the
    // reboot affordance folds into the Stock segment instead of swapping in a
    // taller "reboot" card that resized the whole thing. AnimatedSize only ever
    // absorbs the small text reflow, never a layout swap.
    return RepaintBoundary(
      child: _HeroShell(
        background: background,
        border: Border.all(color: borderColor, width: 1.5),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 340),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _statusContent(context),
        ),
      ),
    );
  }

  Widget _statusContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final inj = mode == WifiMode.inject && !needsReboot;
    // True while a live switch runs (but not the armed-reboot state): the block
    // reads as stepped loading progress instead of a static status line.
    final switching = busy && !needsReboot;
    // When the Stock segment is armed for reboot the top block reads as a
    // reboot prompt, but the layout (icon + text + segmented switch) is
    // identical to every other state, so nothing jumps size.
    final (icon, baseTitle, subtitle) = needsReboot
        ? (
            Icons.restart_alt,
            'Reboot needed',
            'Tap Reboot again to restore stock Wi-Fi.',
          )
        : switch (mode) {
            WifiMode.stock => (
                Icons.wifi,
                'Stock Wi-Fi',
                'Built-in Wi-Fi is on.',
              ),
            WifiMode.inject => (
                Icons.security,
                'Inject Wi-Fi',
                'Injection stack loaded.',
              ),
            WifiMode.off => (
                Icons.wifi_off,
                'Wi-Fi is off',
                'No stack loaded.',
              ),
          };
    final title = switching
        ? (mode == WifiMode.stock ? 'Switching to Stock…' : 'Switching to Inject…')
        : baseTitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _HeroIcon(
              icon: icon,
              bg: inj ? scheme.primary : scheme.surfaceContainerHighest,
              fg: inj ? scheme.onPrimary : scheme.onSurfaceVariant,
              // Slide the icon the same way the segmented tablet travels:
              // Inject sits on the right (+1), Stock/Reboot on the left (-1).
              slideSign: needsReboot
                  ? -1
                  : switch (mode) {
                      WifiMode.inject => 1,
                      WifiMode.stock => -1,
                      WifiMode.off => 0,
                    },
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
                  key: ValueKey((mode, needsReboot, switching)),
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
                    if (switching)
                      _SwitchSteps(toInject: mode == WifiMode.inject)
                    else
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
        _WifiSegmented(
          mode: mode,
          needsReboot: needsReboot,
          busy: busy,
          onSelect: onSelect,
          onReboot: onReboot,
        ),
        // Re-hand the loaded adapter to Android's Wi-Fi framework as a managed
        // station (e.g. after using it in monitor mode). Only meaningful in
        // Inject mode with an adapter driver actually loaded.
        if (mode == WifiMode.inject && !needsReboot && canReconfigure) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Jelly(child: OutlinedButton.icon(
              onPressed: reconfiguring ? null : onReconfigure,
              icon: reconfiguring
                  ? MorphingPolygon(size: 18, color: scheme.primary)
                  : const Icon(Icons.settings_backup_restore, size: 20),
              label: Text(
                reconfiguring ? 'Reconfiguring…' : 'Reconfigure for Android Wi-Fi',
              ),
            )),
          ),
        ],
      ],
    );
  }
}

/// The two-way Wi-Fi switch: a track with a single tablet that slides between
/// the stock vendor stack and our injection stack. `off` slides the tablet out
/// (both segments read as unselected). Custom (not [SegmentedButton]) so the
/// selection glides across on a pill, matching the bottom bar's tablet.
///
/// Returning to stock needs a cold reboot on this hardware, so instead of a
/// separate reboot card the left segment arms in place: tapping Stock slides
/// the tablet onto it and morphs its label/icon to Reboot; tapping it again
/// fires [onReboot] (which confirms, then reboots); tapping Inject cancels.
class _WifiSegmented extends StatelessWidget {
  const _WifiSegmented({
    required this.mode,
    required this.needsReboot,
    required this.busy,
    required this.onSelect,
    required this.onReboot,
  });

  final WifiMode mode;
  final bool needsReboot;

  /// A switch is mid-flight — the whole toggle greys out and stops taking taps
  /// until it settles, so you can't fire a second switch over the first.
  final bool busy;
  final ValueChanged<WifiMode> onSelect;
  final VoidCallback onReboot;

  static const double _pad = 5;
  static const double _height = 52;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isOff = mode == WifiMode.off && !needsReboot;
    // Armed-for-reboot pins the tablet on the left (Reboot) segment regardless
    // of the still-live inject mode underneath.
    final index = (!needsReboot && mode == WifiMode.inject) ? 1 : 0;

    final track = LayoutBuilder(
      builder: (context, constraints) {
        final cellW = (constraints.maxWidth - _pad * 2) / 2;
        return Container(
          height: _height,
          padding: const EdgeInsets.all(_pad),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Stack(
            children: [
              // The sliding tablet — hidden (faded out) while Wi-Fi is off.
              // easeOutCubic stops at the target (no overshoot past the wall);
              // the JellyStretch supplies the squish-into-wall.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                top: 0,
                bottom: 0,
                left: cellW * index,
                width: cellW,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: isOff ? 0 : 1,
                  child: JellyStretch(
                    trigger: index,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ),
              // Positioned.fill so the labels fill the track height and centre
              // vertically — a bare Row here is aligned to the Stack's top
              // corner, which shoved the text up out of the tablet.
              Positioned.fill(
                child: Row(
                  children: [
                    _WifiSeg(
                      label: needsReboot ? 'Reboot' : 'Stock',
                      icon: needsReboot ? Icons.restart_alt : Icons.wifi,
                      selected: needsReboot || (!isOff && mode == WifiMode.stock),
                      onTap: () {
                        // Armed → fire the reboot flow; otherwise arm it.
                        if (needsReboot) {
                          onReboot();
                        } else if (mode != WifiMode.stock) {
                          onSelect(WifiMode.stock);
                        }
                      },
                    ),
                    _WifiSeg(
                      label: 'Inject',
                      icon: Icons.security,
                      selected: !needsReboot && !isOff && mode == WifiMode.inject,
                      onTap: () {
                        // While armed, this cancels back to Inject (handled in
                        // _setWifi); otherwise it's the normal switch.
                        if (needsReboot || mode != WifiMode.inject) {
                          onSelect(WifiMode.inject);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    // Grey out and swallow taps while a switch is in flight, so the toggle
    // can't fire a second switch over the first.
    return IgnorePointer(
      ignoring: busy,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: busy ? 0.45 : 1.0,
        child: track,
      ),
    );
  }
}

class _WifiSeg extends StatelessWidget {
  const _WifiSeg({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.onPrimary : scheme.onSurfaceVariant;

    return Expanded(
      child: JellyTap(
        onTap: onTap,
        // Fill the full cell height so the whole glowing tablet is tappable,
        // not just the band where the icon+label sit.
        child: SizedBox(
          height: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The live "what's happening now" line under the hero title while a switch
/// runs: it steps through the phases the root script goes through (unload,
/// load cfg80211/mac80211, restart services, bring Wi-Fi up) so the wait reads
/// as real progress. The switch itself is one root round-trip — these labels
/// are paced by a timer to roughly track it, not driven by live stdout, and it
/// holds on the last step until the card leaves the switching state.
class _SwitchSteps extends StatefulWidget {
  const _SwitchSteps({required this.toInject});

  final bool toInject;

  @override
  State<_SwitchSteps> createState() => _SwitchStepsState();
}

class _SwitchStepsState extends State<_SwitchSteps> {
  Timer? _timer;
  int _i = 0;

  static const _injectSteps = <String>[
    'Disabling Wi-Fi…',
    'Unloading vendor stack…',
    'Loading cfg80211…',
    'Loading mac80211…',
    'Bringing injection up…',
  ];

  static const _stockSteps = <String>[
    'Disabling Wi-Fi…',
    'Unloading injection stack…',
    'Loading vendor cfg80211 / mac80211…',
    'Loading qca_cld3…',
    'Restarting Wi-Fi services…',
    'Bringing stock Wi-Fi up…',
  ];

  List<String> get _steps => widget.toInject ? _injectSteps : _stockSteps;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1400), (t) {
      if (_i < _steps.length - 1) {
        setState(() => _i++);
      } else {
        t.cancel(); // hold the last step until the switch finishes
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerLeft,
      child: ClipRect(
        child: Align(
          alignment: Alignment.centerLeft,
          child: ReelText(
            text: _steps[_i],
            alignment: Alignment.centerLeft,
            style: Theme.of(context)
                .textTheme
                .bodySmall!
                .copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
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
  const _HeroIcon({
    required this.icon,
    required this.bg,
    required this.fg,
    this.slideSign = 0,
  });

  final IconData icon;
  final Color bg;
  final Color fg;

  /// Which way the icon slides on a change: +1 enters from the right (Inject),
  /// -1 from the left (Stock/Reboot), 0 just cross-fades (Off).
  final int slideSign;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
      width: 54,
      height: 54,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0.5 * slideSign, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: Icon(icon, key: ValueKey(icon), color: fg, size: 27),
      ),
    );
  }
}

/// The live netdev an adapter's driver exposes (e.g. `wlan0`), matched by
/// bound driver name — null while the driver isn't loaded/hasn't brought an
/// interface up yet. Shared by the row's status label and its tap target.
WifiInterface? matchingIface(DetectedAdapter adapter, List<WifiInterface> interfaces) {
  final driver = adapter.device.driver;
  if (driver.isEmpty) return null;
  for (final i in interfaces) {
    if (i.driver.isNotEmpty && i.driver == driver) return i;
  }
  return null;
}

class _AdapterRow extends StatefulWidget {
  const _AdapterRow({
    required this.adapter,
    required this.state,
    required this.iface,
    required this.controller,
    required this.busy,
    required this.onLoad,
  });

  final DetectedAdapter adapter;
  final SystemState state;

  /// The adapter's live netdev, if its driver is loaded and up — the row only
  /// unfolds its controls when this is non-null.
  final WifiInterface? iface;
  final AppController controller;
  final bool busy;
  final VoidCallback onLoad;

  @override
  State<_AdapterRow> createState() => _AdapterRowState();
}

class _AdapterRowState extends State<_AdapterRow> {
  bool _expanded = false;

  @override
  void didUpdateWidget(_AdapterRow old) {
    super.didUpdateWidget(old);
    // Unplugged, or its driver went away: fold back so the next adapter to
    // take this slot doesn't inherit an open panel.
    if (widget.iface == null) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final adapter = widget.adapter;
    final state = widget.state;
    final iface = widget.iface;
    final busy = widget.busy;
    final scheme = Theme.of(context).colorScheme;
    final device = adapter.device;
    final kind = classifyUsb(adapter);

    // The driver this device needs / uses: the one bound in the running kernel
    // if any, else the driver our known-adapter table maps it to.
    final moduleKey = adapter.recognized ? adapter.match!.driver : '';
    final driverName =
        device.driver.isNotEmpty ? device.driver : moduleKey;

    // Presence in the app = a matching .ko is staged; in the system = a driver
    // is bound now, or that staged module is loaded.
    ModuleInfo? appModule;
    if (moduleKey.isNotEmpty) {
      final key = moduleKey.replaceAll('-', '_');
      for (final m in state.modules) {
        if (m.name == moduleKey || m.krName == key) {
          appModule = m;
          break;
        }
      }
    }
    final loaded = appModule?.loaded ?? false;
    final inSystem = device.driver.isNotEmpty || loaded;

    final canLoad = adapter.recognized && appModule != null && !inSystem;

    final Widget trailing;
    if (busy) {
      trailing = MorphingPolygon(
        key: const ValueKey('busy'),
        size: 32,
        color: scheme.primary,
      );
    } else if (canLoad) {
      trailing = Jelly(child: FilledButton.tonal(
        key: const ValueKey('idle'),
        onPressed: widget.onLoad,
        child: const Text('Load'),
      ));
    } else if (inSystem) {
      // With an interface the chevron alone carries the row: the name is
      // already the first thing the unfolded panel says, so a tablet repeating
      // it just crowds the edge.
      trailing = iface != null
          ? const SizedBox.shrink(key: ValueKey('iface'))
          : _StatusTablet(
              key: const ValueKey('active'),
              label: loaded ? 'Loaded' : 'Active',
              bg: scheme.tertiaryContainer,
              fg: scheme.onTertiaryContainer,
            );
    } else if (adapter.recognized) {
      // Known Wi-Fi adapter but its .ko isn't staged in the app.
      trailing = _StatusTablet(
        key: const ValueKey('missing'),
        label: 'Not found',
        bg: scheme.surfaceContainerHighest,
        fg: scheme.onSurfaceVariant,
      );
    } else {
      trailing = const SizedBox.shrink(key: ValueKey('none'));
    }

    // A recognised adapter whose driver .ko isn't staged: nothing to load, so
    // the whole row dims to read as inert (no tap target, no error to trip).
    final notFound = !busy && adapter.recognized && !inSystem && !canLoad;

    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: adapter.recognized
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        child: Icon(
          _kindIcon(kind),
          color: adapter.recognized
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
          size: 20,
        ),
      ),
      title: Text(device.displayName, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        driverName.isNotEmpty
            ? '${device.idPair} · $driverName'
            : '${device.idPair} · no driver',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: SizedBox(
        // Just the chevron once there's an interface — no tablet to fit.
        width: iface == null ? 88 : 28,
        // Centre both the spinner and the resting controls in the box so the busy
        // spinner morphs into the iface tablet at the same centre — no sideways jump.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
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
            // The affordance that the row opens in place rather than going
            // somewhere — only drawn when there is something to unfold.
            if (iface != null)
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: Icon(Icons.keyboard_arrow_down,
                    size: 20, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );

    // Dim the whole row (icon, name, driver line, tablet) so "Not found" reads
    // as inert rather than a live, tappable adapter.
    final dimmed = notFound ? Opacity(opacity: 0.5, child: tile) : tile;

    // Only a row with controls to unfold gets the jelly squash — everything
    // else stays a plain, inert row.
    // GestureDetector, not InkWell: the jelly squash is the press feedback, and
    // a Material ripple washing white over the row on top of it read as a
    // second, competing effect.
    final head = iface == null
        ? dimmed
        : Jelly(
            pressScale: 0.978,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _expanded = !_expanded);
              },
              child: dimmed,
            ),
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        head,
        // One height animator for the unfold; the panel itself only fades in,
        // so nothing nested fights it.
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded && iface != null
              ? AdapterConfigView(
                  key: ValueKey('cfg-${iface.name}'),
                  ifaceName: iface.name,
                  controller: widget.controller,
                  inline: true,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// An icon representing what a plugged device is for.
IconData _kindIcon(UsbKind kind) => switch (kind) {
      UsbKind.wifi => Icons.wifi_tethering,
      UsbKind.bluetooth => Icons.bluetooth,
      UsbKind.can => Icons.directions_car_filled_outlined,
      UsbKind.serial => Icons.cable,
      UsbKind.network => Icons.lan_outlined,
      UsbKind.storage => Icons.sd_storage_outlined,
      UsbKind.hub => Icons.hub_outlined,
      UsbKind.other => Icons.usb,
    };

/// A compact status tablet (Loaded / Active / No driver) for a device row.
class _StatusTablet extends StatelessWidget {
  const _StatusTablet({
    super.key,
    required this.label,
    required this.bg,
    required this.fg,
  });

  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13),
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
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.usb_off, color: scheme.onSurfaceVariant, size: 22),
            const SizedBox(width: 14),
            Text(
              'No USB devices detected.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
