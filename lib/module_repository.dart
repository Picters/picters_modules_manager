import 'module_info.dart';
import 'root_shell.dart';

const String kModulesDir = '/system/lib/modules';

/// Same Wi-Fi/injection classification as nh-modules.sh's NH_WIFI list in the
/// kernel CI repo (Kokuban_Kernel_CI_Center/ci_core_rs/src) — cfg80211/mac80211
/// plus every chipset driver that conflicts with the vendor qca_cld3 stack.
const Set<String> kWifiClassModules = <String>{
  'cfg80211', 'mac80211',
  '88XXau', '8188eu', '8814au', '88x2bu',
  'rtl8xxxu', 'rtlwifi', 'rtl_usb', 'rtl8187', 'rtl8192cu', 'rtl8192c-common',
  'ath', 'ath9k_hw', 'ath9k_common', 'ath9k_htc', 'ath6kl_core', 'ath6kl_usb',
  'carl9170', 'mt7601u',
  'rt2x00lib', 'rt2x00usb', 'rt2800lib', 'rt2800usb', 'rt2500usb', 'rt73usb',
  'zd1211rw', 'usb_net_rndis_wlan',
};

const String _vendorWifiModule = 'qca_cld3_peach_v2';
const String _split = '___PMM_SPLIT___';

/// Thrown by [ModuleRepository.setLoaded] when a precondition fails before any
/// shell command runs at all — e.g. turning an adapter on before cfg80211/
/// mac80211 are loaded. The caller never touches su for these; they're pure
/// Dart-side checks against the last scan.
class ModulePrecondition implements Exception {
  const ModulePrecondition(this.message);
  final String message;

  @override
  String toString() => message;
}

class ModuleRepository {
  Future<ScanResult> scan() async {
    final r = await RootShell.run(
      '[ -d $kModulesDir ] && echo DIR_OK\n'
      'ls $kModulesDir/*.ko 2>/dev/null\n'
      'echo $_split\n'
      'cat /proc/modules 2>/dev/null\n',
    );

    final parts = r.stdout.split(_split);
    final beforeSplit = parts.isNotEmpty ? parts[0] : '';
    final procModules = parts.length > 1 ? parts[1] : '';

    final dirExists = beforeSplit.contains('DIR_OK');
    final loaded = _parseLoadedNames(procModules);

    final modules = <ModuleInfo>[];
    for (final rawLine in beforeSplit.split('\n')) {
      final path = rawLine.trim();
      if (!path.endsWith('.ko')) continue;
      final base = path.split('/').last;
      final name = base.substring(0, base.length - 3);
      final krName = name.replaceAll('-', '_');
      modules.add(ModuleInfo(
        name: name,
        loaded: loaded.contains(krName),
        isWifiClass: kWifiClassModules.contains(name),
      ));
    }
    modules.sort((a, b) {
      if (a.isWifiClass != b.isWifiClass) return a.isWifiClass ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return ScanResult(
      modules: modules,
      vendorWifiLoaded: loaded.contains(_vendorWifiModule),
      modulesDirExists: dirExists,
    );
  }

  Set<String> _parseLoadedNames(String procModules) {
    final loaded = <String>{};
    for (final line in procModules.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      loaded.add(t.split(RegExp(r'\s+')).first);
    }
    return loaded;
  }

  /// Turns [module] on/off. For Wi-Fi-class modules this is now strictly
  /// manual/layered — enabling an adapter never silently pulls in cfg80211/
  /// mac80211 for it; it throws [ModulePrecondition] instead so the caller can
  /// surface a plain "enable X first" message without touching root at all.
  /// [currentlyLoaded] is the module list from the last scan, used to figure
  /// out what a cfg80211/mac80211 "restore stock" needs to unwind first.
  Future<ShellResult> setLoaded(
    ModuleInfo module,
    bool wantLoaded,
    List<ModuleInfo> currentlyLoaded,
  ) {
    if (wantLoaded) {
      _checkEnablePrecondition(module, currentlyLoaded);
      if (module.name == 'cfg80211') {
        return RootShell.run(_enableCfg80211Script());
      }
      return RootShell.run("insmod '$kModulesDir/${module.name}.ko' 2>&1\n");
    }
    if (module.name == 'cfg80211') {
      return RootShell.run(_restoreStockScript(currentlyLoaded));
    }
    if (module.name == 'mac80211') {
      return RootShell.run(_disableMac80211Script(currentlyLoaded));
    }
    return RootShell.run("rmmod '${module.krName}' 2>&1\n");
  }

  void _checkEnablePrecondition(ModuleInfo module, List<ModuleInfo> loaded) {
    if (!module.isWifiClass || module.name == 'cfg80211') return;
    final cfgLoaded = _isLoaded(loaded, 'cfg80211');
    if (!cfgLoaded) {
      throw const ModulePrecondition('Enable cfg80211 first');
    }
    if (module.name == 'mac80211') return;
    if (!_isLoaded(loaded, 'mac80211')) {
      throw const ModulePrecondition('Enable mac80211 first');
    }
  }

  bool _isLoaded(List<ModuleInfo> modules, String name) =>
      modules.any((m) => m.name == name && m.loaded);

  /// The only place vendor Wi-Fi teardown happens — deliberately scoped to
  /// cfg80211's own "on" action, not cascaded in from toggling some adapter.
  String _enableCfg80211Script() {
    final b = StringBuffer();
    b.writeln("if grep -q '^$_vendorWifiModule ' /proc/modules; then");
    b.writeln('  svc wifi disable 2>/dev/null');
    b.writeln('  sleep 2');
    b.writeln('  rmmod $_vendorWifiModule 2>/dev/null');
    b.writeln('fi');
    b.writeln("insmod '$kModulesDir/cfg80211.ko' 2>&1");
    return b.toString();
  }

  /// Best-effort: rmmod any loaded wifi adapter that isn't cfg80211/mac80211.
  String _rmmodDependentAdapters(List<ModuleInfo> loaded) {
    final b = StringBuffer();
    for (final m in loaded) {
      if (m.loaded && m.isWifiClass && m.name != 'cfg80211' && m.name != 'mac80211') {
        b.writeln("rmmod '${m.krName}' 2>/dev/null");
      }
    }
    return b.toString();
  }

  String _disableMac80211Script(List<ModuleInfo> loaded) {
    final b = StringBuffer();
    b.write(_rmmodDependentAdapters(loaded));
    b.writeln('rmmod mac80211 2>&1');
    return b.toString();
  }

  /// Turning cfg80211 off means "give me stock Wi-Fi back": unwind our whole
  /// stack (adapters, then mac80211, then cfg80211 itself), then try to bring
  /// the vendor qca_cld3 stack back up without a reboot. The .ko itself is a
  /// vendor file we never packaged, so it should still be sitting under
  /// /vendor or /vendor_dlkm where it was before we rmmod'd it — this looks
  /// for it there rather than guessing a fixed path. Prints a final
  /// grep of /proc/modules so the caller can tell whether it actually worked,
  /// instead of just assuming success like the old inject.sh "off" no-op did.
  String _restoreStockScript(List<ModuleInfo> loaded) {
    final b = StringBuffer();
    b.write(_rmmodDependentAdapters(loaded));
    b.writeln('rmmod mac80211 2>/dev/null');
    b.writeln('rmmod cfg80211 2>&1');
    b.writeln("if ! grep -q '^$_vendorWifiModule ' /proc/modules; then");
    b.writeln('  svc wifi enable 2>/dev/null');
    b.writeln('  sleep 2');
    b.writeln("  if ! grep -q '^$_vendorWifiModule ' /proc/modules; then");
    b.writeln(
      "    VMOD=\$(find /vendor /vendor_dlkm -name '$_vendorWifiModule.ko' 2>/dev/null | head -1)",
    );
    b.writeln('    [ -n "\$VMOD" ] && insmod "\$VMOD" 2>&1');
    b.writeln('    svc wifi enable 2>/dev/null');
    b.writeln('  fi');
    b.writeln('fi');
    b.writeln("echo RESTORE_CHECK:");
    b.writeln('grep -c "^$_vendorWifiModule " /proc/modules');
    return b.toString();
  }

  /// True if the last setLoaded() call was a cfg80211 "restore stock" attempt
  /// that actually got the vendor Wi-Fi module back (parses the marker printed
  /// by [_restoreStockScript]). Returns null if this wasn't a restore attempt.
  bool? restoreSucceeded(ShellResult result) {
    final marker = result.stdout.indexOf('RESTORE_CHECK:');
    if (marker == -1) return null;
    final after = result.stdout.substring(marker + 'RESTORE_CHECK:'.length).trim();
    final count = int.tryParse(after.split('\n').first.trim()) ?? 0;
    return count > 0;
  }
}
