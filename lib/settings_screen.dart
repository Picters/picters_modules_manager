import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_bridge.dart';
import 'control_surfaces.dart';
import 'settings_controller.dart';
import 'widgets.dart';
import 'theme.dart';

/// Settings opened from the gear, with the creator card after the settings.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.preview = false,
  });

  final bool preview;

  final SettingsController controller;

  Future<void> _setBootLoad(bool value) async {
    HapticFeedback.selectionClick();
    await controller.setBootLoadEnabled(value);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            const SectionHeader(icon: Icons.tune, label: 'General'),
            const SizedBox(height: 12),
            Card.outlined(
              child: _BootLoadCard(
                enabled: controller.bootLoadEnabled,
                onChanged: _setBootLoad,
              ),
            ),
            const SizedBox(height: 10),
            Card.outlined(
              child: Jelly(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  minTileHeight: 56,
                  minVerticalPadding: 0,
                  leading: const ControlIcon(Icons.add_to_home_screen_outlined),
                  title: const ControlRowTitle('Add to home screen'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    if (preview) {
                      showInfo(
                        context,
                        'Shortcuts are available on the phone.',
                      );
                      return;
                    }
                    final requested = await NativeBridge.requestPinShortcut();
                    if (!context.mounted) return;
                    if (requested) {
                      showInfo(context, 'Shortcut requested.');
                    } else {
                      showError(
                        context,
                        'The launcher could not add a shortcut.',
                      );
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 26),
            const SectionHeader(
              icon: Icons.bug_report_outlined,
              label: 'Diagnostics',
            ),
            const SizedBox(height: 12),
            _DebugCard(controller: controller, preview: preview),
            const SizedBox(height: 26),
            const SectionHeader(icon: Icons.code, label: 'GitHub'),
            const SizedBox(height: 12),
            const CreatorCard(),
          ],
        );
      },
    );
  }
}

/// Toggles whether the boot-time loader (service.sh) auto-loads every staged
/// non-Wi-Fi module on Android startup. Off by default — nothing loads at boot
/// until the user opts in here.
class _BootLoadCard extends StatelessWidget {
  const _BootLoadCard({required this.enabled, required this.onChanged});

  final bool enabled;
  final Future<void> Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    // No busy spinner and no disabling: the switch's own travel is the
    // feedback, and swapping this icon mid-press is what made it stutter.
    return JellySwitchTile(
      secondary: ControlIcon(Icons.flash_on, active: enabled),
      title: 'Load modules on boot',
      value: enabled,
      onChanged: onChanged,
    );
  }
}

/// Collects a diagnostics bundle (last_kmsg + dmesg + logcat) into one archive,
/// then lets the user share it, save it somewhere, or discard it.
class _DebugCard extends StatefulWidget {
  const _DebugCard({required this.controller, this.preview = false});

  final bool preview;

  final SettingsController controller;

  @override
  State<_DebugCard> createState() => _DebugCardState();
}

class _DebugCardState extends State<_DebugCard> {
  bool _busy = false;

  Future<void> _collect() async {
    if (widget.preview) {
      _toast('Diagnostics are available on the phone.');
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    final path = await widget.controller.collectDebugLogs();
    if (!mounted) return;
    setState(() => _busy = false);
    if (path == null) {
      showError(context, 'Could not collect logs.');
      return;
    }
    await _showResult(path);
  }

  Future<void> _showResult(String path) async {
    final name = path.split('/').last;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => _ResultSheet(
        fileName: name,
        onShare: () async {
          Navigator.pop(sheetCtx);
          final ok = await NativeBridge.shareFile(path);
          if (!ok && mounted) _toast('Nothing handled the share.');
        },
        onSave: () async {
          Navigator.pop(sheetCtx);
          final ok = await NativeBridge.saveFile(path, name);
          if (mounted) _toast(ok ? 'Saved.' : 'Save cancelled.');
          if (ok) await widget.controller.deleteDebugLogs(path);
        },
      ),
    );
  }

  void _toast(String msg) => showInfo(context, msg);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.outlined(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        minTileHeight: 56,
        minVerticalPadding: 0,
        leading: _busy
            ? SizedBox(
                width: 24,
                height: 24,
                child: MorphingPolygon(size: 24, color: scheme.primary),
              )
            : const ControlIcon(Icons.description_outlined),
        title: const ControlRowTitle('Collect diagnostics'),
        trailing: _busy ? null : const Icon(Icons.chevron_right),
        onTap: _busy ? null : _collect,
      ),
    );
  }
}

/// The choice after an archive is built: share it or save it somewhere.
/// Dismissing the sheet just leaves it (overwritten on the next collect).
class _ResultSheet extends StatelessWidget {
  const _ResultSheet({
    required this.fileName,
    required this.onShare,
    required this.onSave,
  });

  final String fileName;
  final VoidCallback onShare;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Logs collected', style: textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              fileName,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Jelly(
              child: FilledButton.icon(
                onPressed: onShare,
                icon: const Icon(Icons.share_outlined),
                label: const Text('Share'),
              ),
            ),
            const SizedBox(height: 10),
            Jelly(
              child: FilledButton.tonalIcon(
                onPressed: onSave,
                icon: const Icon(Icons.save_alt),
                label: const Text('Save…'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CreatorCard extends StatelessWidget {
  const CreatorCard({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.outlined(
      child: Jelly(
        pressScale: 0.978,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          minTileHeight: 56,
          minVerticalPadding: 0,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Image.asset(
              'assets/images/picters-avatar.jpg',
              width: 42,
              height: 42,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.account_circle_outlined, size: 42),
            ),
          ),
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Picters',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                'github.com/Picters',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          trailing: Icon(Icons.north_east, size: 18, color: scheme.primary),
          onTap: () async {
            final opened = await NativeBridge.openUrl(
              'https://github.com/Picters',
            );
            if (!opened && context.mounted) {
              showError(context, 'Could not open GitHub.');
            }
          },
        ),
      ),
    );
  }
}
