import 'module_info.dart';
import 'root_shell.dart';
import 'usb_devices.dart';

const String kModulesDir = '/system/lib/modules';

/// cfg80211/mac80211 + every chipset driver that conflicts with the vendor
/// qca_cld3 stack (same set as the kernel CI's old nh-modules.sh NH_WIFI list).
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
/// an adapter while the NetHunter Wi-Fi stack is off.
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
        : (cfg ? WifiMode.nethunter : WifiMode.off);

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

  bool _has(List<ModuleInfo> modules, String name) =>
      modules.any((m) => m.name == name && m.loaded);

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
  Future<ShellResult> switchToNetHunter(List<ModuleInfo> modules) {
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
    b.writeln('rmmod cfg80211 2>/dev/null');
    b.writeln("insmod '$kModulesDir/cfg80211.ko' 2>&1");
    if (modules.any((m) => m.name == 'mac80211')) {
      b.writeln("grep -q '^mac80211 ' /proc/modules || insmod '$kModulesDir/mac80211.ko' 2>&1");
    }
    b.writeln("grep -q '^cfg80211 ' /proc/modules && echo OK_NH");
    return RootShell.run(b.toString());
  }

  /// Unwind our whole stack and bring the stock vendor Wi-Fi back without a
  /// reboot if possible. Verifies via /proc/modules rather than assuming.
  ///
  /// The vendor's own cfg80211.ko (see switchToNetHunter's doc) still has to
  /// be reloaded BEFORE qca_cld3 — qca_cld3 won't insmod against our cfg80211
  /// (wrong symbol versions). It's a vendor file we never touched, so it
  /// should still be sitting wherever it was at boot; this searches for it
  /// rather than guessing a fixed path, same as it already did for qca_cld3.
  /// Whether cnss2 (the platform driver actually doing WLAN firmware
  /// download) accepts a second attach without a reboot is the one thing
  /// this can't verify without a real device — everything module-side that
  /// CAN be gotten right is handled here.
  Future<ShellResult> switchToStock(List<ModuleInfo> modules) {
    final b = StringBuffer();
    for (final m in modules) {
      if (m.loaded &&
          m.isWifiClass &&
          m.name != 'cfg80211' &&
          m.name != 'mac80211') {
        b.writeln("rmmod '${m.krName}' 2>/dev/null");
      }
    }
    b.writeln('rmmod mac80211 2>/dev/null');
    b.writeln('rmmod cfg80211 2>/dev/null');
    b.writeln("if ! grep -q '^$_vendorWifi ' /proc/modules; then");
    b.writeln("  if ! grep -q '^cfg80211 ' /proc/modules; then");
    b.writeln(
      "    VCFG=\$(find /vendor /vendor_dlkm -name 'cfg80211.ko' 2>/dev/null | head -1)",
    );
    b.writeln('    [ -n "\$VCFG" ] && insmod "\$VCFG" 2>&1');
    b.writeln('  fi');
    b.writeln("  V=\$(find /vendor /vendor_dlkm -name '$_vendorWifi.ko' 2>/dev/null | head -1)");
    b.writeln('  [ -n "\$V" ] && insmod "\$V" 2>&1');
    b.writeln('  svc wifi enable 2>/dev/null');
    b.writeln('  sleep 2');
    b.writeln("  if ! grep -q '^$_vendorWifi ' /proc/modules; then");
    // One retry cycle: some Qualcomm WLAN HALs need Wi-Fi service bounced
    // twice before it re-attaches to a freshly re-inserted driver.
    b.writeln('    svc wifi disable 2>/dev/null');
    b.writeln('    sleep 1');
    b.writeln('    svc wifi enable 2>/dev/null');
    b.writeln('    sleep 2');
    b.writeln('  fi');
    b.writeln('fi');
    b.writeln('echo STOCK_CHECK:');
    b.writeln("grep -c '^$_vendorWifi ' /proc/modules");
    return RootShell.run(b.toString());
  }

  bool stockRestored(ShellResult r) {
    final i = r.stdout.indexOf('STOCK_CHECK:');
    if (i < 0) return false;
    final tail = r.stdout.substring(i + 'STOCK_CHECK:'.length).trim();
    return (int.tryParse(tail.split('\n').first.trim()) ?? 0) > 0;
  }

  // ── Individual module toggle (the deep-config tab) ──────────────────────

  Future<ShellResult> setLoaded(
    ModuleInfo module,
    bool wantLoaded,
    List<ModuleInfo> current,
  ) {
    if (wantLoaded) {
      if (module.isWifiClass &&
          module.name != 'cfg80211' &&
          module.name != 'mac80211') {
        if (!_has(current, 'cfg80211')) {
          throw const ModulePrecondition('Enable cfg80211 first');
        }
        if (!_has(current, 'mac80211')) {
          throw const ModulePrecondition('Enable mac80211 first');
        }
      }
      if (module.name == 'cfg80211') {
        // Loading cfg80211 by hand still needs the vendor teardown first —
        // and the vendor's OWN cfg80211.ko has to come out too (same module
        // name as ours, can't coexist), or this insmod fails with EEXIST.
        final b = StringBuffer();
        b.writeln("if grep -q '^$_vendorWifi ' /proc/modules; then");
        b.writeln('  svc wifi disable 2>/dev/null');
        b.writeln('  sleep 2');
        b.writeln('  rmmod $_vendorWifi 2>/dev/null');
        b.writeln('fi');
        b.writeln('rmmod cfg80211 2>/dev/null');
        b.writeln("insmod '$kModulesDir/cfg80211.ko' 2>&1");
        return RootShell.run(b.toString());
      }
      return RootShell.run("insmod '$kModulesDir/${module.name}.ko' 2>&1");
    }
    return RootShell.run("rmmod '${module.krName}' 2>&1");
  }
}
