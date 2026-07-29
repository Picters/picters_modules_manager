import 'dart:io';

import 'module_info.dart';
import 'native_bridge.dart';

/// A long-running root action that was in flight when the app last ran.
///
/// These actions take tens of seconds (a Wi-Fi stack switch bounces the HAL and
/// wificond; a Reconfigure reloads the chipset and restarts services), and this
/// phone's launcher is quick to kill a backgrounded app. When that happens the
/// shell command itself keeps running to completion — it lives in the root
/// service's process, not ours — but the reply has nowhere to land, so on the
/// next start the app would come up looking idle while the device was still
/// mid-switch.
///
/// So the intent is written down *before* the command goes out and erased when
/// it returns. Finding one at startup means "this was running when we died":
/// the spinner is put back and the live state is watched until it shows the
/// action landed, or until the action's own timeout has passed.
enum PendingKind {
  wifiStock,
  wifiInject,
  reconfigure,
  moduleLoad,
  moduleUnload,
}

class PendingOp {
  const PendingOp({
    required this.kind,
    required this.target,
    required this.startedAt,
    required this.timeout,
  });

  final PendingKind kind;

  /// Module name for a load/unload, interface name for a reconfigure, empty for
  /// the Wi-Fi mode switches.
  final String target;

  final DateTime startedAt;

  /// How long the action gets before it's written off. Mirrors the timeout on
  /// the matching [ModuleRepository] call, plus room for the settle.
  final Duration timeout;

  DateTime get deadline => startedAt.add(timeout);

  /// True once the action can no longer plausibly be running — the process it
  /// belonged to is gone and its own timeout has elapsed, so a marker still on
  /// disk is stale rather than live.
  bool expiredAt(DateTime now) => now.isAfter(deadline);

  /// Single line, so the file is written and parsed without a JSON dependency.
  String encode() => [
        kind.name,
        target,
        startedAt.millisecondsSinceEpoch,
        timeout.inSeconds,
      ].join('|');

  /// Null for anything unparseable — a truncated or half-written file must read
  /// as "nothing pending" rather than wedging the UI behind a phantom spinner.
  static PendingOp? decode(String raw) {
    final parts = raw.trim().split('|');
    if (parts.length < 4) return null;
    PendingKind? kind;
    for (final k in PendingKind.values) {
      if (k.name == parts[0]) kind = k;
    }
    final millis = int.tryParse(parts[2]);
    final seconds = int.tryParse(parts[3]);
    if (kind == null || millis == null || seconds == null) return null;
    return PendingOp(
      kind: kind,
      target: parts[1],
      startedAt: DateTime.fromMillisecondsSinceEpoch(millis),
      timeout: Duration(seconds: seconds),
    );
  }

  /// What the UI says while the restored action is being watched.
  String get label => switch (kind) {
        PendingKind.wifiStock => 'Restoring stock Wi-Fi…',
        PendingKind.wifiInject => 'Enabling Inject mode…',
        PendingKind.reconfigure => 'Reconfiguring $target…',
        PendingKind.moduleLoad => 'Loading $target…',
        PendingKind.moduleUnload => 'Unloading $target…',
      };

  /// Whether [state] shows the action actually landed. This is the only way to
  /// find out after a restart: the command's own exit code died with the
  /// process, so the system's own state is the sole remaining evidence.
  bool isSatisfiedBy(SystemState state) {
    switch (kind) {
      case PendingKind.wifiStock:
        return state.wifiMode == WifiMode.stock;
      case PendingKind.wifiInject:
        return state.wifiMode == WifiMode.inject;
      case PendingKind.moduleLoad:
        for (final m in state.modules) {
          if (m.name == target) return m.loaded;
        }
        return false;
      case PendingKind.moduleUnload:
        for (final m in state.modules) {
          if (m.name == target) return !m.loaded;
        }
        // Gone from the staged set entirely — certainly not loaded.
        return true;
      case PendingKind.reconfigure:
        // Handed to the Android framework means: the interface is back, admin-up
        // and out of monitor mode. Reconfigure may rename it to wlan0, so an
        // interface matching either name counts.
        for (final i in state.interfaces) {
          if (i.name != target && i.name != 'wlan0') continue;
          if (i.up && !i.monitor) return true;
        }
        return false;
    }
  }
}

/// Reads and writes the single pending-action marker in the app's own private
/// files dir — plain Dart file I/O, no root involved, the same place the
/// updater keeps its reboot marker.
class PendingOpStore {
  Future<File?> _file() async {
    final dir = await NativeBridge.filesDir();
    return dir == null ? null : File('$dir/pending_op');
  }

  Future<void> write(PendingOp op) async {
    try {
      final f = await _file();
      await f?.writeAsString(op.encode(), flush: true);
    } catch (_) {
      // Best effort: failing to record the intent must never stop the action
      // the user actually asked for.
    }
  }

  Future<PendingOp?> read() async {
    try {
      final f = await _file();
      if (f == null || !await f.exists()) return null;
      return PendingOp.decode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      final f = await _file();
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }
}
