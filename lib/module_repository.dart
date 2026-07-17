import 'module_info.dart';
import 'root_shell.dart';
import 'usb_devices.dart';

const String kModulesDir = '/system/lib/modules';

/// cfg80211/mac80211 + every chipset driver that conflicts with the vendor
/// qca_cld3 stack (same set the module's boot service.sh skips at load time).
const Set<String> kWifiClassModules = <String>{
  'cfg80211', 'mac80211',
  '88XXau', '8188eu', '8814au', '88x2bu',
  'rtl8xxxu', 'rtlwifi', 'rtl_usb', 'rtl8187', 'rtl8192cu', 'rtl8192c-common',
  'ath', 'ath9k_hw', 'ath9k_common', 'ath9k_htc', 'ath6kl_core', 'ath6kl_usb',
  'carl9170', 'mt7601u',
  'rt2x00lib', 'rt2x00usb', 'rt2800lib', 'rt2800usb', 'rt2500usb', 'rt73usb',
  'zd1211rw', 'usb_net_rndis_wlan',
};

const String _vendorWifi = 'qca_cld3_peach_v2';
const String _mModules = '___PMM_MODS___';
const String _mProc = '___PMM_PROC___';

/// Thrown before any root command runs when a precondition fails — e.g. loading
/// an adapter while the injection Wi-Fi stack is off.
class ModulePrecondition implements Exception {
  const ModulePrecondition(this.message);
  final String message;
  @override
  String toString() => message;
}

class ModuleRepository {
  /// One `su` round-trip for the whole picture: module files, /proc/modules,
  /// and USB devices. Kept to a single call so 1s polling stays cheap.
  Future<SystemState> scan() async {
    final r = await RootShell.run(
      'echo $_mModules; '
      '[ -d $kModulesDir ] && echo DIR_OK; '
      'ls $kModulesDir/*.ko 2>/dev/null; '
      'echo $_mProc; '
      'cat /proc/modules 2>/dev/null; '
      'echo ${_mProc}_USB; '
      '$usbScanFragment',
    );

    final lines = r.stdout.split('\n');
    int section = 0; // 0=pre, 1=modules, 2=proc, 3=usb
    final modFiles = <String>[];
    final loaded = <String>{};
    var dirExists = false;
    final usbLines = <String>[];

    for (final raw in lines) {
      final line = raw.trim();
      if (line == _mModules) {
        section = 1;
        continue;
      }
      if (line == _mProc) {
        section = 2;
        continue;
      }
      if (line == '${_mProc}_USB') {
        section = 3;
        continue;
      }
      switch (section) {
        case 1:
          if (line == 'DIR_OK') {
            dirExists = true;
          } else if (line.endsWith('.ko')) {
            modFiles.add(line);
          }
          break;
        case 2:
          if (line.isNotEmpty) loaded.add(line.split(RegExp(r'\s+')).first);
          break;
        case 3:
          usbLines.add(raw);
          break;
      }
    }

    final modules = <ModuleInfo>[];
    for (final path in modFiles) {
      final base = path.split('/').last;
      final name = base.substring(0, base.length - 3);
      modules.add(ModuleInfo(
        name: name,
        loaded: loaded.contains(name.replaceAll('-', '_')),
        isWifiClass: kWifiClassModules.contains(name),
      ));
    }
    modules.sort((a, b) {
      if (a.isWifiClass != b.isWifiClass) return a.isWifiClass ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    final vendorLoaded = loaded.contains(_vendorWifi);
    final cfg = loaded.contains('cfg80211');
    final mac = loaded.contains('mac80211');
    final mode = vendorLoaded
        ? WifiMode.stock
        : (cfg ? WifiMode.inject : WifiMode.off);

    return SystemState(
      modules: modules,
      adapters: parseUsbLines(usbLines),
      wifiMode: mode,
      cfgLoaded: cfg,
      macLoaded: mac,
      vendorWifiLoaded: vendorLoaded,
      modulesDirExists: dirExists,
    );
  }

  // ── High-level Wi-Fi mode switch (the main screen) ──────────────────────

  /// Result of a mode switch: [ok] plus a human message for the UI.
  ///
  /// There are TWO separate cfg80211.ko builds on this device: ours (shipped
  /// in system/lib/modules, ABI-matched to the injection drivers) and the
  /// vendor's (loaded at boot from /vendor or /vendor_dlkm, ABI-matched to
  /// qca_cld3 — different CRCs, see project memory
  /// project_injection_cfg80211_architecture.md). Removing qca_cld3 does NOT
  /// remove the vendor cfg80211 module itself — it stays loaded. The old
  /// version of this script only checked "is *a* cfg80211 loaded" and skipped
  /// insmod'ing ours if so, which meant it silently never actually switched
  /// once the vendor one was resident. Fixed: unconditionally evict whatever
  /// cfg80211 is currently there before loading ours.
  Future<ShellResult> switchToInject(List<ModuleInfo> modules) {
    final hasCfg = modules.any((m) => m.name == 'cfg80211');
    if (!hasCfg) {
      throw const ModulePrecondition('cfg80211.ko is not staged in this module');
    }
    final b = StringBuffer();
    b.writeln("if grep -q '^$_vendorWifi ' /proc/modules; then");
    b.writeln('  svc wifi disable 2>/dev/null');
    b.writeln('  sleep 2');
    b.writeln('  rmmod $_vendorWifi 2>/dev/null');
    b.writeln('fi');
    // Whatever cfg80211 is loaded right now (vendor's, almost certainly) has
    // to go before ours can take its place — same module name, can't coexist.
    // mac80211 registers itself as a cfg80211 client at insmod time, so
    // cfg80211 stays EBUSY (rmmod fails) as long as ANY mac80211 — vendor's
    // or ours — is still resident, even if mac80211 itself has zero
    // dependents right now. Confirmed on-device: without this, rmmod
    // cfg80211 exits 1 every time, our insmod then fails "File exists"
    // against the still-resident (vendor) cfg80211, and the old grep-based
    // success check couldn't tell "a cfg80211 is loaded" from "OUR cfg80211
    // is loaded" — so it reported OK_INJECT while nothing had actually switched,
    // and mac80211/the adapter drivers loaded against the wrong cfg80211
    // next, which is what threw "disagrees about version of symbol".
    b.writeln('rmmod mac80211 2>/dev/null');
    b.writeln('rmmod cfg80211 2>/dev/null');
    // insmod's own exit status is the only reliable success signal — unlike
    // grepping /proc/modules for the name "cfg80211", it can't be fooled by
    // a stale module of the same name still being resident. Retry a few
    // times a second apart for the transient teardown race, re-attempting
    // the rmmods each time in case the previous insmod's "File exists"
    // failure left something to clear out.
    b.writeln('i=0');
    b.writeln('LOADED_OURS=0');
    b.writeln('while [ "\$i" -lt 3 ]; do');
    b.writeln("  if insmod '$kModulesDir/cfg80211.ko' 2>&1; then");
    b.writeln('    LOADED_OURS=1');
    b.writeln('    break');
    b.writeln('  fi');
    b.writeln('  rmmod mac80211 2>/dev/null');
    b.writeln('  rmmod cfg80211 2>/dev/null');
    b.writeln('  i=\$((i + 1))');
    b.writeln('  sleep 1');
    b.writeln('done');
    b.writeln('if [ "\$LOADED_OURS" -eq 1 ]; then');
    if (modules.any((m) => m.name == 'mac80211')) {
      b.writeln("  grep -q '^mac80211 ' /proc/modules || insmod '$kModulesDir/mac80211.ko' 2>&1");
    }
    b.writeln('  echo OK_INJECT');
    b.writeln('else');
    b.writeln('  echo DMESG_TAIL:');
    b.writeln("  dmesg 2>/dev/null | grep -iE 'cfg80211|mac80211' | tail -n 15");
    b.writeln('fi');
    return RootShell.run(b.toString());
  }

  /// Restoring the stock vendor Wi-Fi is intentionally NOT attempted in
  /// software: confirmed on-device, once qca_cld3's rmmod drops the WLAN PCIe
  /// link the chip's config space reads back 0xffff within ~2s and nothing
  /// short of a cold reboot brings it back — bouncing the Wi-Fi service, a
  /// plain PCI unbind/bind, and even a real hardware FLR reset were all tried
  /// live and none worked. So the UI goes straight to a reboot prompt (a
  /// reboot restores stock cleanly: OOT modules unload on boot, the vendor
  /// stack loads normally) and this just performs it.
  Future<void> reboot() => RootShell.run('reboot', timeout: const Duration(seconds: 3));

  /// The dmesg tail any of switchToStock/switchToInject/setLoaded append
  /// after a `DMESG_TAIL:` marker — for surfacing to the user or attaching
  /// to a bug report when an automatic action doesn't work.
  String? dmesgTail(ShellResult r) {
    final i = r.stdout.indexOf('DMESG_TAIL:');
    if (i < 0) return null;
    final tail = r.stdout.substring(i + 'DMESG_TAIL:'.length).trim();
    return tail.isEmpty ? null : tail;
  }

  // ── Individual module toggle (the deep-config tab) ──────────────────────

  /// Loads or unloads a single module. Dependency ordering is resolved a level
  /// up (the controller, via module_dependencies.dart) and executed through
  /// [loadChain]/[unloadChain]; this is the plain one-module path used when a
  /// module has nothing else to pull in.
  Future<ShellResult> setLoaded(ModuleInfo module, bool wantLoaded) {
    if (wantLoaded) {
      if (module.name == 'cfg80211') {
        // Loading cfg80211 by hand still needs the vendor teardown first —
        // and the vendor's OWN cfg80211.ko has to come out too (same module
        // name as ours, can't coexist), or this insmod fails with EEXIST.
        // mac80211 has to go first: it registers as a cfg80211 client at
        // insmod time, so cfg80211 stays EBUSY on rmmod while ANY mac80211
        // is still resident, even one with zero dependents of its own —
        // see switchToInject's doc for how this bit us on-device.
        final b = StringBuffer();
        b.writeln("if grep -q '^$_vendorWifi ' /proc/modules; then");
        b.writeln('  svc wifi disable 2>/dev/null');
        b.writeln('  sleep 2');
        b.writeln('  rmmod $_vendorWifi 2>/dev/null');
        b.writeln('fi');
        b.writeln('rmmod mac80211 2>/dev/null');
        b.writeln('rmmod cfg80211 2>/dev/null');
        b.writeln("insmod '$kModulesDir/cfg80211.ko' 2>&1");
        return RootShell.run(b.toString());
      }
      return RootShell.run(_insmodWithRetryScript(module));
    }
    return RootShell.run("rmmod '${module.krName}' 2>&1");
  }

  /// insmod several modules in dependency order (deepest dependency first),
  /// each with the same settle-retry as a single load; stops at the first that
  /// won't come up, reporting it as `CHAIN_FAIL:<name>`. The app resolves the
  /// order itself (see module_dependencies.dart) — there's no modules.dep on
  /// this device for `modprobe` to use.
  Future<ShellResult> loadChain(List<ModuleInfo> ordered) => RootShell.run(
        _loadChainScript(ordered),
        timeout: Duration(seconds: 20 + 10 * ordered.length),
      );

  String _loadChainScript(List<ModuleInfo> ordered) {
    final b = StringBuffer();
    for (final m in ordered) {
      final path = "$kModulesDir/${m.name}.ko";
      b.writeln('OUT=""');
      b.writeln('i=0');
      b.writeln('while [ "\$i" -lt 3 ]; do');
      b.writeln("  OUT=\$(insmod '$path' 2>&1)");
      b.writeln("  grep -q '^${m.krName} ' /proc/modules && break");
      b.writeln('  i=\$((i + 1))');
      b.writeln('  sleep 1');
      b.writeln('done');
      b.writeln("if ! grep -q '^${m.krName} ' /proc/modules; then");
      b.writeln('  echo "CHAIN_FAIL:${m.name}"');
      b.writeln('  echo "\$OUT"');
      b.writeln('  exit 0');
      b.writeln('fi');
    }
    b.writeln('echo OK_CHAIN');
    return b.toString();
  }

  /// rmmod several modules in order (outermost users first), stopping at the
  /// first that won't unload — used to clear a shared module's dependents
  /// before removing it, instead of failing with a bare "Module is in use".
  Future<ShellResult> unloadChain(List<ModuleInfo> ordered) => RootShell.run(
        _unloadChainScript(ordered),
        timeout: Duration(seconds: 15 + 5 * ordered.length),
      );

  String _unloadChainScript(List<ModuleInfo> ordered) {
    final b = StringBuffer();
    for (final m in ordered) {
      b.writeln("OUT=\$(rmmod '${m.krName}' 2>&1)");
      b.writeln("if grep -q '^${m.krName} ' /proc/modules; then");
      b.writeln('  echo "CHAIN_FAIL:${m.name}"');
      b.writeln('  echo "\$OUT"');
      b.writeln('  exit 0');
      b.writeln('fi');
    }
    b.writeln('echo OK_CHAIN');
    return b.toString();
  }

  /// null when a loadChain/unloadChain reported OK_CHAIN, otherwise the name of
  /// the module the chain stopped on.
  String? chainFailure(ShellResult r) {
    if (r.stdout.contains('OK_CHAIN')) return null;
    return RegExp(r'CHAIN_FAIL:(\S+)').firstMatch(r.stdout)?.group(1);
  }

  /// insmod, with a couple of retries a second apart. Fixes a real race: right
  /// after cfg80211/mac80211 come up they're already visible in /proc/modules
  /// (so the precondition check above passes), but the wireless core can need a
  /// moment longer before it's actually ready to accept a new adapter
  /// registering against it — a driver probing too early gets "Invalid
  /// argument" from insmod even though nothing is really wrong; the exact
  /// same insmod succeeds a second later. Retrying here means the user
  /// doesn't have to notice that and retry by hand (as happened before this
  /// fix — toggling Inject mode off/on again just gave it more time to
  /// settle before the next attempt).
  ///
  /// The dmesg tail is deliberately NOT collected here — it's fetched lazily by
  /// [moduleDmesg] only if the user taps the error icon, so a failed toggle
  /// returns fast and never holds the (serialized) root shell blocking the next
  /// module the user tries to toggle.
  String _insmodWithRetryScript(ModuleInfo module) {
    final path = "$kModulesDir/${module.name}.ko";
    final b = StringBuffer();
    b.writeln('OUT=""');
    b.writeln('i=0');
    b.writeln('while [ "\$i" -lt 3 ]; do');
    b.writeln("  OUT=\$(insmod '$path' 2>&1)");
    b.writeln("  grep -q '^${module.krName} ' /proc/modules && break");
    b.writeln('  i=\$((i + 1))');
    b.writeln('  sleep 1');
    b.writeln('done');
    b.writeln('echo "\$OUT"');
    return b.toString();
  }

  /// On-demand dmesg tail for one module — run only when the user taps a row's
  /// error icon, never as part of a toggle (see [_insmodWithRetryScript]).
  Future<String> moduleDmesg(ModuleInfo module) async {
    final r = await RootShell.run(
      "dmesg 2>/dev/null | grep -iE '${module.krName}' | tail -n 20",
    );
    return r.stdout.trim();
  }

  /// The insmod/rmmod output itself, excluding the DMESG_TAIL section that
  /// [_insmodWithRetryScript] appends — ShellResult.errorSummary would
  /// otherwise report the last dmesg line instead of the actual command
  /// output when a script has diagnostics tacked on.
  String loadErrorSummary(ShellResult r) {
    final i = r.stdout.indexOf('DMESG_TAIL:');
    final head = i >= 0 ? r.stdout.substring(0, i) : r.stdout;
    final lines =
        head.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
    return lines.isEmpty ? 'exit code ${r.exitCode}' : lines.last;
  }
}
