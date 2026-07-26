import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_bridge.dart';
import 'settings_controller.dart';
import 'widgets.dart';

/// App settings — the third tab in the bottom dock. Home for the boot-time
/// auto-load toggle (kept off the Overview screen so that stays a pure status
/// dashboard). Body-only: the app shell supplies the app bar and its title.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final SettingsController controller;

  Future<void> _setBootLoad(bool value) async {
    HapticFeedback.selectionClick();
    await controller.setBootLoadEnabled(value);
  }

  Future<void> _setHidePerf(bool value) async {
    HapticFeedback.selectionClick();
    await controller.setHidePerformance(value);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return ListView(
          // Same iOS-style spring/overscroll bounce as the other screens'
          // PolygonScrollView, even though the short content fits the viewport.
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          children: [
            const SectionHeader(icon: Icons.tune, label: 'General'),
            const SizedBox(height: 12),
            // Both app toggles grouped into one block.
            Card.outlined(
              child: Column(
                children: [
                  _BootLoadCard(
                    enabled: controller.bootLoadEnabled,
                    busy: controller.bootLoadBusy,
                    onChanged: _setBootLoad,
                  ),
                  const CardDivider(),
                  _HidePerfCard(
                    enabled: controller.hidePerformance,
                    onChanged: _setHidePerf,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 26),
            const SectionHeader(
                icon: Icons.new_releases_outlined, label: 'Installed build'),
            const SizedBox(height: 12),
            _ChangelogCard(controller: controller),
            const SizedBox(height: 26),
            const SectionHeader(icon: Icons.bug_report, label: 'Debug'),
            const SizedBox(height: 12),
            _DebugCard(controller: controller),
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
    return SwitchListTile(
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
    );
  }
}

/// Hides the Performance tab from the bottom bar.
class _HidePerfCard extends StatelessWidget {
  const _HidePerfCard({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      secondary: Icon(Icons.speed_outlined, color: scheme.onSurfaceVariant),
      title: const Text('Hide Performance screen'),
      subtitle: const Text('Removes the Performance tab from the bottom bar.'),
      value: enabled,
      onChanged: onChanged,
    );
  }
}

/// Opens the changelog that shipped inside the installed Modules pack — the
/// kernel and the pack come out of one build, so it covers both.
class _ChangelogCard extends StatefulWidget {
  const _ChangelogCard({required this.controller});

  final SettingsController controller;

  @override
  State<_ChangelogCard> createState() => _ChangelogCardState();
}

class _ChangelogCardState extends State<_ChangelogCard> {
  bool _busy = false;

  Future<void> _open() async {
    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    final log = await widget.controller.installedChangelog();
    if (!mounted) return;
    setState(() => _busy = false);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ChangelogSheet(version: log.version, text: log.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.outlined(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: _busy
            ? SizedBox(
                width: 24,
                height: 24,
                child: MorphingPolygon(size: 24, color: scheme.primary),
              )
            : Icon(Icons.history_edu_outlined, color: scheme.onSurfaceVariant),
        title: const Text("What's new"),
        subtitle: const Text(
          'Changelog of the kernel & modules build on this device.',
        ),
        trailing: _busy ? null : const Icon(Icons.chevron_right),
        onTap: _busy ? null : _open,
      ),
    );
  }
}

class _ChangelogSheet extends StatelessWidget {
  const _ChangelogSheet({required this.version, required this.text});

  final String version;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final empty = text.isEmpty;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("What's new", style: textTheme.titleLarge),
              if (version.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  version,
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    empty
                        ? 'This build predates in-app changelogs, or the '
                            'Modules pack is not installed. The next update '
                            'will carry one.'
                        : text,
                    style: textTheme.bodyMedium?.copyWith(
                      color: empty ? scheme.onSurfaceVariant : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Collects a diagnostics bundle (last_kmsg + dmesg + logcat) into one archive,
/// then lets the user share it, save it somewhere, or discard it.
class _DebugCard extends StatefulWidget {
  const _DebugCard({required this.controller});

  final SettingsController controller;

  @override
  State<_DebugCard> createState() => _DebugCardState();
}

class _DebugCardState extends State<_DebugCard> {
  bool _busy = false;

  Future<void> _collect() async {
    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    final path = await widget.controller.collectDebugLogs();
    if (!mounted) return;
    setState(() => _busy = false);
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not collect logs.', textAlign: TextAlign.start),
        ),
      );
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

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg, textAlign: TextAlign.start)),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.outlined(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: _busy
            ? SizedBox(
                width: 24,
                height: 24,
                child: MorphingPolygon(size: 24, color: scheme.primary),
              )
            : Icon(Icons.description_outlined, color: scheme.onSurfaceVariant),
        title: const Text('Collect diagnostics'),
        subtitle: const Text(
          'Bundle last_kmsg, dmesg and logcat into one archive.',
        ),
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
              style: textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onShare,
              icon: const Icon(Icons.share_outlined),
              label: const Text('Share'),
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: onSave,
              icon: const Icon(Icons.save_alt),
              label: const Text('Save…'),
            ),
          ],
        ),
      ),
    );
  }
}
