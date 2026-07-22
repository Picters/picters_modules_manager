import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'native_bridge.dart';
import 'root_shell.dart';

/// Bundled asset for the statically-linked `iw` (nl80211 config tool) — plain
/// Android doesn't ship one (only `ip` from toybox), so a static arm64 build
/// rides along in the APK and gets extracted to the app's files dir on first
/// use. See docs/iw for how it was cross-compiled.
const String kIwAsset = 'assets/bin/iw';

/// Bundled official wireless-regdb `regulatory.db`. This device ships without
/// one, so cfg80211 has no regulatory rules and `iw reg set` can't move off the
/// world domain ("00"). We drop it into a firmware search path the kernel's
/// sysfs fallback loader checks, then `iw reg reload` makes cfg80211 pick it up.
/// (Needs the injection kernel built with CFG80211_REQUIRE_SIGNED_REGDB off —
/// the stock signed-regdb check rejects even the official db on this build.)
const String kRegDbAsset = 'assets/bin/regulatory.db';

/// Writable firmware path the kernel's ueventd sysfs fallback searches for
/// regulatory.db (confirmed on-device; the read-only /vendor & /odm paths can't
/// be written from a systemless setup).
const String kRegDbDir = '/data/vendor/bdf';
const String kRegDbPath = '$kRegDbDir/regulatory.db';

/// Per-interface facts [IwRepository.query] reads via `iw`.
class IwInfo {
  const IwInfo({
    required this.txPowerDbm,
    required this.regDomain,
    required this.regDomainLocked,
  });

  /// Current transmit power in dBm, or null if `iw` couldn't report it.
  final double? txPowerDbm;

  /// The two-letter regulatory domain actually governing THIS radio's own phy
  /// — not just whichever "country" line happens to print last, since a
  /// self-managed phy (common for the built-in chip) prints its own domain
  /// separately from the global one every other radio follows.
  final String? regDomain;

  /// True when this radio is a "self-managed" wiphy: the driver owns its own
  /// regulatory state and `iw reg set` — which only ever changes the global
  /// domain — has no effect on it. [IwRepository.setRegulatoryDomain] would
  /// silently no-op here, so the UI should say so instead of offering it.
  final bool regDomainLocked;
}

/// Regulatory domain with no power/channel restrictions — used by pentesting
/// tools (aircrack-ng, wifite) to unlock higher tx power / extra channels for
/// injection work. Applying it is the user's explicit, confirmed choice; nothing
/// here applies it automatically.
const String kUnrestrictedRegDomain = 'BO';

/// Down/set-type/up so a mode change actually takes on a live interface —
/// bracketing it this way (rather than setting type while up) is what
/// airmon-ng/wifite do and is the one sequence chipset drivers reliably accept.
String iwSetModeScript(String iwPath, String iface, bool monitor) {
  final type = monitor ? 'monitor' : 'managed';
  return "ip link set '$iface' down 2>/dev/null; "
      "'$iwPath' dev '$iface' set type $type 2>&1; "
      "ip link set '$iface' up 2>/dev/null; "
      'echo OK_MODE';
}

/// Plain link up/down — this alone is toybox's `ip`, no `iw` involved.
String iwSetLinkScript(String iface, bool up) =>
    "ip link set '$iface' ${up ? 'up' : 'down'} 2>&1; echo OK_LINK";

/// Stages [regDbAssetPath] (already extracted to the app's files dir) into the
/// kernel firmware path, reloads cfg80211's regdb from it, then sets the domain.
/// `iw reg reload` does a fresh request_firmware that overwrites any cached
/// boot-time load error, so this recovers without a reboot even when the db
/// wasn't present when cfg80211 first came up.
String iwSetRegDomainScript(String iwPath, String alpha2, String regDbSrc) =>
    "mkdir -p '$kRegDbDir' 2>/dev/null; "
    "cp '$regDbSrc' '$kRegDbPath' 2>/dev/null; "
    "chmod 644 '$kRegDbPath' 2>/dev/null; "
    "chcon u:object_r:vendor_firmware_file:s0 '$kRegDbPath' 2>/dev/null; "
    "'$iwPath' reg reload 2>&1; "
    'sleep 1; '
    "'$iwPath' reg set $alpha2 2>&1; "
    'sleep 1; '
    'echo OK_REG';

/// [dbm] is whole dBm; `iw` wants mBm (hundredths of a dBm).
String iwSetTxPowerScript(String iwPath, String iface, int dbm) =>
    "'$iwPath' dev '$iface' set txpower fixed ${dbm * 100} 2>&1; echo OK_TXPOWER";

String iwQueryScript(String iwPath, String iface) =>
    "'$iwPath' dev '$iface' info 2>/dev/null; "
    "echo __IW_REG__; '$iwPath' reg get 2>/dev/null";

// Matches a NON-NEGATIVE txpower only — these Realtek drivers report a bogus
// "txpower -100.00 dBm" when the value is uninitialised/unreadable, and the
// leading '-' (absent from the class) makes that line simply not match → null.
final RegExp _txPowerLine = RegExp(r'txpower\s+([\d.]+)\s*dBm');
final RegExp _wiphyLine = RegExp(r'^wiphy\s+(\d+)');
final RegExp _countryLine = RegExp(r'^country\s+([A-Za-z0-9]{2}):');
final RegExp _phyHeader = RegExp(r'^phy#(\d+)\s*(\(self-managed\))?');

double? parseTxPowerDbm(String iwDevInfoOutput) {
  for (final raw in iwDevInfoOutput.split('\n')) {
    final m = _txPowerLine.firstMatch(raw.trim());
    if (m != null) {
      final v = double.tryParse(m.group(1)!);
      // Reject the driver's out-of-range sentinels; real Wi-Fi tx power is
      // 0..~35 dBm, so anything above that isn't a real reading.
      if (v != null && v > 0 && v <= 40) return v;
    }
  }
  return null;
}

/// The wiphy index `iw dev <iface> info` reports (the "wiphy N" line) — used
/// to pick the right section out of `iw reg get`'s output, which lists every
/// radio separately.
int? parseWiphyIndex(String iwDevInfoOutput) {
  for (final raw in iwDevInfoOutput.split('\n')) {
    final m = _wiphyLine.firstMatch(raw.trim());
    if (m != null) return int.tryParse(m.group(1)!);
  }
  return null;
}

/// The regulatory domain governing wiphy [wiphyIndex] specifically: its own
/// `phy#<n>` block if `iw reg get` prints one (self-managed phys always get
/// their own block), else the `global` domain every other radio follows.
/// [wiphyIndex] null (couldn't be determined) also falls back to global.
({String? domain, bool selfManaged}) parseRegDomainForPhy(
  String iwRegGetOutput,
  int? wiphyIndex,
) {
  String? global;
  String? phyDomain;
  var phySelfManaged = false;
  var section = '';
  for (final raw in iwRegGetOutput.split('\n')) {
    final line = raw.trim();
    if (line == 'global') {
      section = 'global';
      continue;
    }
    final ph = _phyHeader.firstMatch(line);
    if (ph != null) {
      section = 'phy#${ph.group(1)}';
      if (wiphyIndex != null && ph.group(1) == '$wiphyIndex') {
        phySelfManaged = ph.group(2) != null;
      }
      continue;
    }
    final c = _countryLine.firstMatch(line);
    if (c == null) continue;
    final domain = c.group(1)!.toUpperCase();
    if (section == 'global') global = domain;
    if (wiphyIndex != null && section == 'phy#$wiphyIndex') phyDomain = domain;
  }
  return (domain: phyDomain ?? global, selfManaged: phySelfManaged);
}

IwInfo parseIwQuery(String output) {
  const marker = '__IW_REG__';
  final idx = output.indexOf(marker);
  final infoPart = idx >= 0 ? output.substring(0, idx) : output;
  final regPart = idx >= 0 ? output.substring(idx + marker.length) : '';
  final reg = parseRegDomainForPhy(regPart, parseWiphyIndex(infoPart));
  return IwInfo(
    txPowerDbm: parseTxPowerDbm(infoPart),
    regDomain: reg.domain,
    regDomainLocked: reg.selfManaged,
  );
}

/// Resolves the on-device path to an extracted bundled asset. Overridable in
/// tests so [IwRepository]'s action methods can be asserted on without a
/// Flutter asset-bundle binding.
typedef AssetResolver = Future<String?> Function();

/// Copies a bundled asset to the app's files dir (plain Dart file I/O — no root
/// needed, it's the app's own private storage) and skips the rewrite once it's
/// already there with the right size. Returns the on-device path.
Future<String?> _extractAsset(String assetKey, String destName) async {
  final dir = await NativeBridge.filesDir();
  if (dir == null) return null;
  final path = '$dir/$destName';
  final data = await rootBundle.load(assetKey);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final file = File(path);
  final upToDate = await file.exists() && await file.length() == bytes.length;
  if (!upToDate) {
    await file.writeAsBytes(bytes, flush: true);
  }
  return path;
}

Future<String?> _defaultIwResolver() => _extractAsset(kIwAsset, 'iw');
Future<String?> _defaultRegDbResolver() =>
    _extractAsset(kRegDbAsset, 'regulatory.db');

/// Per-interface radio control backed by the bundled static `iw` binary:
/// monitor/managed mode, link up/down, regulatory domain, and tx power. Every
/// write is a real hardware-supported `iw`/`ip` call — nothing here spoofs or
/// bypasses the driver, it just exposes controls already native to it.
class IwRepository {
  IwRepository([
    RootRunner runner = const DefaultRootRunner(),
    AssetResolver? resolver,
    AssetResolver? regDbResolver,
  ])  : _shell = runner,
        _resolver = resolver ?? _defaultIwResolver,
        _regDbResolver = regDbResolver ?? _defaultRegDbResolver;

  final RootRunner _shell;
  final AssetResolver _resolver;
  final AssetResolver _regDbResolver;
  String? _cachedPath;

  /// Extracts+chmods the bundled binary once per app run and caches the path.
  Future<String?> ensureBinary() async {
    final cached = _cachedPath;
    if (cached != null) return cached;
    final path = await _resolver();
    if (path == null) return null;
    await _shell.run("chmod 755 '$path' 2>/dev/null");
    _cachedPath = path;
    return path;
  }

  Future<IwInfo?> query(String iface) async {
    final iw = await ensureBinary();
    if (iw == null) return null;
    final r = await _shell.run(iwQueryScript(iw, iface));
    return parseIwQuery(r.stdout);
  }

  Future<ShellResult> setMode({required String iface, required bool monitor}) async {
    final iw = await ensureBinary();
    if (iw == null) return const ShellResult(-1, 'iw unavailable');
    return _shell.run(
      iwSetModeScript(iw, iface, monitor),
      timeout: const Duration(seconds: 15),
    );
  }

  Future<ShellResult> setLinkUp({required String iface, required bool up}) =>
      _shell.run(iwSetLinkScript(iface, up));

  Future<ShellResult> setRegulatoryDomain(String alpha2) async {
    final iw = await ensureBinary();
    if (iw == null) return const ShellResult(-1, 'iw unavailable');
    final regDb = await _regDbResolver();
    if (regDb == null) return const ShellResult(-1, 'regulatory.db unavailable');
    return _shell.run(
      iwSetRegDomainScript(iw, alpha2, regDb),
      timeout: const Duration(seconds: 15),
    );
  }

  Future<ShellResult> setTxPower({required String iface, required int dbm}) async {
    final iw = await ensureBinary();
    if (iw == null) return const ShellResult(-1, 'iw unavailable');
    return _shell.run(iwSetTxPowerScript(iw, iface, dbm));
  }

  // ── Persisted tx power per driver: stock (first valid reading) + last-set ──
  // These Realtek drivers won't reliably read tx power back (they report a bogus
  // "-100 dBm"), so we can't trust a live query. Instead we persist, per driver:
  //   • "stock" — the first VALID reading ever seen (the marker; never changed).
  //   • "set"   — the last value the user applied (what the slider restores to).
  // Both survive panel reopens and app restarts. Keyed by driver so a re-plug
  // of the same adapter keeps its values.

  Map<String, Map<String, int>>? _tx;
  String? _txPath;

  Future<void> _loadTx() async {
    if (_tx != null) return;
    _tx = {};
    final dir = await NativeBridge.filesDir();
    if (dir == null) return;
    _txPath = '$dir/txpower.json';
    try {
      final f = File(_txPath!);
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _tx = {
          for (final e in m.entries)
            e.key: {
              for (final k in (e.value as Map).entries)
                k.key as String: (k.value as num).toInt(),
            },
        };
      }
    } catch (_) {}
  }

  Future<void> _saveTx() async {
    final p = _txPath;
    if (p != null) {
      try {
        await File(p).writeAsString(jsonEncode(_tx));
      } catch (_) {}
    }
  }

  /// Warm the persisted store into memory so the sync getters below are ready
  /// before the panel's first paint (no value "jump" on open).
  Future<void> preloadTx() => _loadTx();

  /// Synchronous reads from the in-memory store (null if not yet warmed) — used
  /// so the slider opens straight at its known value instead of flashing the
  /// recommended default first.
  int? lastSetTxSync(String driver) => _tx?[driver]?['set'];
  int? stockTxSync(String driver) => _tx?[driver]?['stock'];

  /// The persisted stock (first-valid) tx power for [driver], or null if none
  /// has been captured yet.
  Future<int?> stockTx(String driver) async {
    await _loadTx();
    return _tx![driver]?['stock'];
  }

  /// Records [dbm] as [driver]'s stock the first time only (never overwritten).
  Future<void> recordStockTx(String driver, int dbm) async {
    await _loadTx();
    final d = _tx!.putIfAbsent(driver, () => {});
    if (d.containsKey('stock')) return;
    d['stock'] = dbm;
    await _saveTx();
  }

  /// The last tx power the user applied for [driver], or null.
  Future<int?> lastSetTx(String driver) async {
    await _loadTx();
    return _tx![driver]?['set'];
  }

  Future<void> recordSetTx(String driver, int dbm) async {
    await _loadTx();
    _tx!.putIfAbsent(driver, () => {})['set'] = dbm;
    await _saveTx();
  }
}
