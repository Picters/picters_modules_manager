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
const String _vendorDlkmDir = '/vendor_dlkm/lib/modules';
const String _mModules = '___PMM_MODS___';
const String _mProc = '___PMM_PROC___';

/// Lives outside /data/adb/modules so it survives a Modules pack
/// reinstall/update — service.sh checks this flag before auto-loading.
const String kBootConfigDir = '/data/adb/picters_modules_manager';
const String kBootLoadFlag = '$kBootConfigDir/boot_load_enabled';

/// Cosmetic app flag (same config dir): hides the Performance tab.
const String kHidePerfFlag = '$kBootConfigDir/hide_performance';

/// Thrown before any root command runs when a precondition fails — e.g. loading
/// an adapter while the injection Wi-Fi stack is off.
class ModulePrecondition implements Exception {
  const ModulePrecondition(this.message);
  final String message;
  @override
  String toString() => message;
}

/// True when the netdev's `flags` hex bitmask has IFF_UP (bit 0) set — the
/// admin up/down state (what `ip link set up/down` drives), unlike operstate
/// which stays "unknown"/"down" for a monitor VIF or an unassociated station.
bool ifaceFlagUp(String flags) {
  var s = flags.trim().toLowerCase();
  if (s.startsWith('0x')) s = s.substring(2);
  final v = int.tryParse(s, radix: 16) ?? 0;
  return v & 0x1 != 0; // IFF_UP
}

/// Parses the lines produced by [ifaceScanFragment] into [WifiInterface]s.
List<WifiInterface> parseIfaceLines(Iterable<String> lines) {
  final out = <WifiInterface>[];
  for (final line in lines) {
    final idx = line.indexOf(ifaceMarker);
    if (idx < 0) continue;
    final f = line.substring(idx + ifaceMarker.length).split('|');
    final name = f.isNotEmpty ? f[0].trim() : '';
    if (name.isEmpty) continue;
    out.add(WifiInterface(
      name: name,
      driver: f.length > 1 ? f[1].trim() : '',
      up: f.length > 2 && ifaceFlagUp(f[2]),
      monitor: f.length > 3 && f[3].trim() == '803',
    ));
  }
  return out;
}

/// The device-identity props the updater gates on.
class DeviceIdentity {
  const DeviceIdentity({
    required this.socModel,
    required this.brand,
    required this.marketName,
  });

  /// `ro.soc.model`, e.g. "SM8850" — the whole Xiaomi 17 series shares it.
  final String socModel;

  /// `ro.product.brand`, e.g. "Xiaomi".
  final String brand;

  /// `ro.product.marketname`, e.g. "Xiaomi 17" / "Xiaomi 17 Pro Max".
  final String marketName;

  static const empty =
      DeviceIdentity(socModel: '', brand: '', marketName: '');
}

/// Parses the `SOC:`/`BRAND:`/`MARKET:` lines from [ModuleRepository.deviceIdentity].
DeviceIdentity parseDeviceIdentity(String out) {
  String soc = '', brand = '', market = '';
  for (final raw in out.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('SOC:')) {
      soc = line.substring(4).trim();
    } else if (line.startsWith('BRAND:')) {
      brand = line.substring(6).trim();
    } else if (line.startsWith('MARKET:')) {
      market = line.substring(7).trim();
    }
  }
  return DeviceIdentity(socModel: soc, brand: brand, marketName: market);
}

/// True for a Xiaomi 17-series phone (base / Pro / Pro Max / Ultra). They all
/// use the sm8850 SoC the kernel + OOT modules are built for, so the updater
/// only offers a build to one of these — never to a device it could brick.
/// Accepts either an explicit "Xiaomi 17…" market name or the Xiaomi-branded
/// sm8850 combo (market name is blank on some builds; the SoC never is).
bool isSupportedDevice(DeviceIdentity id) {
  final market = id.marketName.toLowerCase().trim();
  if (market.startsWith('xiaomi 17')) return true;
  return id.brand.toLowerCase().trim() == 'xiaomi' &&
      id.socModel.toLowerCase().trim() == 'sm8850';
}

class ModuleRepository {
  /// [runner] defaults to the real root layer ([DefaultRootRunner]); tests pass
  /// a fake to assert on the emitted scripts and stub results.
  ModuleRepository([RootRunner runner = const DefaultRootRunner()])
      : _shell = runner;

  final RootRunner _shell;

  /// One `su` round-trip for the whole picture: module files, /proc/modules,
  /// USB devices, and wireless interfaces. Kept to a single call so 1s polling
  /// stays cheap.
  Future<SystemState> scan() async {
    final r = await _shell.run(
      'echo $_mModules; '
      '[ -d $kModulesDir ] && echo DIR_OK; '
      'ls $kModulesDir/*.ko 2>/dev/null; '
      'echo $_mProc; '
      'cat /proc/modules 2>/dev/null; '
      'echo ${_mProc}_USB; '
      '$usbScanFragment; '
      'echo ${_mProc}_IFACE; '
      '$ifaceScanFragment',
    );

    final lines = r.stdout.split('\n');
    int section = 0; // 0=pre, 1=modules, 2=proc, 3=usb, 4=iface
    final modFiles = <String>[];
    final loaded = <String>{};
    var dirExists = false;
    final usbLines = <String>[];
    final ifaceLines = <String>[];

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
      if (line == '${_mProc}_IFACE') {
        section = 4;
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
        case 4:
          ifaceLines.add(raw);
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
      interfaces: parseIfaceLines(ifaceLines),
      wifiMode: mode,
      cfgLoaded: cfg,
      macLoaded: mac,
      vendorWifiLoaded: vendorLoaded,
      modulesDirExists: dirExists,
    );
  }

  /// Whether the boot-time loader is currently allowed to auto-load modules.
  Future<bool> bootLoadEnabled() async {
    final r = await _shell.run("[ -f '$kBootLoadFlag' ] && echo Y || echo N");
    return r.stdout.contains('Y');
  }

  Future<void> setBootLoadEnabled(bool enabled) => _shell.run(
        enabled
            ? "mkdir -p '$kBootConfigDir' && touch '$kBootLoadFlag'"
            : "rm -f '$kBootLoadFlag'",
      );

  /// Whether the Performance tab is hidden.
  Future<bool> hidePerformance() async {
    final r = await _shell.run("[ -f '$kHidePerfFlag' ] && echo Y || echo N");
    return r.stdout.contains('Y');
  }

  Future<void> setHidePerformance(bool hide) => _shell.run(
        hide
            ? "mkdir -p '$kBootConfigDir' && touch '$kHidePerfFlag'"
            : "rm -f '$kHidePerfFlag'",
      );

  // ── High-level Wi-Fi mode switch (the main screen) ──────────────────────

  /// Two separate cfg80211.ko builds exist on this device (ours vs the
  /// vendor's, different CRCs); always evict whatever's loaded before
  /// insmod'ing ours, since removing qca_cld3 alone doesn't remove it.
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
    // mac80211 must go first — it pins cfg80211 as EBUSY while resident.
    b.writeln('rmmod mac80211 2>/dev/null');
    b.writeln('rmmod cfg80211 2>/dev/null');
    // Retry a few times for the teardown race; insmod's exit code is the
    // only trustworthy success signal here.
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
    return _shell.run(b.toString());
  }

  /// Live return to stock Wi-Fi — no reboot. Switching to Inject only unloads
  /// qca_cld3, leaving the cnss2/PCIe stack up, so re-inserting the vendor
  /// cfg80211/mac80211/qca_cld3 retrains the link and the built-in chip comes
  /// back. Restarts the HAL + wificond so Settings re-attaches. On failure it
  /// restores our inject stack and appends a DMESG_TAIL for the reboot fallback.
  Future<ShellResult> switchToStock(List<ModuleInfo> modules) {
    final adapters = [
      for (final m in modules)
        if (m.loaded && m.isWifiClass && m.name != 'cfg80211' && m.name != 'mac80211')
          m.krName,
    ];
    final b = StringBuffer();
    b.writeln('V=$_vendorDlkmDir');
    b.writeln('svc wifi disable 2>/dev/null');
    b.writeln('sleep 2');
    for (final a in adapters) {
      b.writeln("rmmod '$a' 2>/dev/null");
    }
    b.writeln('rmmod mac80211 2>/dev/null');
    b.writeln('rmmod cfg80211 2>/dev/null');
    b.writeln('insmod "\$V/cfg80211.ko" 2>/dev/null');
    b.writeln('insmod "\$V/mac80211.ko" 2>/dev/null');
    b.writeln('insmod "\$V/$_vendorWifi.ko" 2>&1');
    b.writeln('sleep 3');
    b.writeln('stop wificond 2>/dev/null || setprop ctl.stop wificond 2>/dev/null');
    b.writeln('stop vendor.wifi_hal_legacy 2>/dev/null || '
        'setprop ctl.stop vendor.wifi_hal_legacy 2>/dev/null');
    b.writeln('sleep 2');
    b.writeln('start vendor.wifi_hal_legacy 2>/dev/null || '
        'setprop ctl.start vendor.wifi_hal_legacy 2>/dev/null');
    b.writeln('sleep 1');
    b.writeln('start wificond 2>/dev/null || setprop ctl.start wificond 2>/dev/null');
    b.writeln('sleep 1');
    b.writeln('svc wifi enable 2>/dev/null');
    b.writeln('sleep 3');
    b.writeln("if grep -q '^$_vendorWifi ' /proc/modules && [ -d /sys/class/net/wlan0 ]; then");
    b.writeln('  echo OK_STOCK');
    b.writeln('else');
    // Live switch failed — put the injection stack back so Wi-Fi isn't left dead,
    // then hand the reboot fallback the dmesg.
    b.writeln("  rmmod $_vendorWifi 2>/dev/null");
    b.writeln('  rmmod mac80211 2>/dev/null');
    b.writeln('  rmmod cfg80211 2>/dev/null');
    b.writeln("  insmod '$kModulesDir/cfg80211.ko' 2>/dev/null");
    b.writeln("  insmod '$kModulesDir/mac80211.ko' 2>/dev/null");
    b.writeln('  echo DMESG_TAIL:');
    b.writeln("  dmesg 2>/dev/null | grep -iE 'qca|cnss|cfg80211|wlan' | tail -n 15");
    b.writeln('fi');
    return _shell.run(b.toString(), timeout: const Duration(seconds: 70));
  }

  /// A hard reboot — the fallback when [switchToStock] can't restore stock live.
  Future<void> reboot() => _shell.run('reboot', timeout: const Duration(seconds: 3));

  /// Hand a loaded adapter back to Settings as a managed station: bounce Wi-Fi,
  /// optionally reload the driver, restart wificond, re-enable (see inline why).
  Future<ShellResult> reconfigureManaged({
    required String chipsetDriver,
    required String iface,
    bool reloadDriver = true,
  }) {
    final kr = chipsetDriver.replaceAll('-', '_');
    final b = StringBuffer();
    b.writeln('IF=$iface');
    b.writeln('svc wifi disable 2>/dev/null');
    b.writeln('sleep 1');
    if (reloadDriver) {
      // Reloads the chipset to drop the monitor VIF / reset RF (no iw here);
      // it re-creates the iface, so recompute IF from the driver's first netdev.
      b.writeln("if grep -q '^$kr ' /proc/modules; then");
      b.writeln("  rmmod '$kr' 2>/dev/null");
      b.writeln('  sleep 1');
      b.writeln("  insmod '$kModulesDir/$chipsetDriver.ko' 2>/dev/null");
      b.writeln('  sleep 2');
      b.writeln('  for n in /sys/class/net/*/; do');
      b.writeln('    [ -d "\${n}phy80211" ] || continue');
      b.writeln('    [ -L "\${n}device/driver" ] || continue');
      b.writeln('    d=\$(basename "\$(readlink "\${n}device/driver")")');
      b.writeln('    if [ "\$d" = "$kr" ] || [ "\$d" = "$chipsetDriver" ]; then');
      b.writeln('      IF=\$(basename "\$n"); break');
      b.writeln('    fi');
      b.writeln('  done');
      b.writeln('fi');
    }
    // Best-effort managed set — only if `iw` exists (it doesn't on stock, so the
    // driver reload above is what actually resets the mode).
    b.writeln('IW=\$(command -v iw 2>/dev/null)');
    b.writeln('if [ -n "\$IW" ]; then');
    b.writeln('  ip link set "\$IF" down 2>/dev/null');
    b.writeln('  "\$IW" dev "\$IF" set type managed 2>/dev/null');
    b.writeln('fi');
    // The framework only drives its configured station iface (wlan0). If the
    // chosen adapter is some other wlanX and no wlan0 exists, rename it so
    // Settings picks it up. Guarded on "no existing wlan0" to avoid a clash.
    b.writeln('if [ "\$IF" != "wlan0" ] && [ ! -d /sys/class/net/wlan0 ]; then');
    b.writeln('  ip link set "\$IF" down 2>/dev/null');
    b.writeln('  if ip link set "\$IF" name wlan0 2>/dev/null; then IF=wlan0; fi');
    b.writeln('fi');
    b.writeln('ip link set "\$IF" up 2>/dev/null');
    // The QCA wifi HAL opens /dev/wlan as its driver-state control param. It must
    // be a CHAR device (sepolicy grants hal_wifi_default vendor_wlan_device:chr_file,
    // not :file — a regular file gets EACCES). Back it by null (1,3) so open/read/
    // write succeed, and label it as the vendor expects via restorecon.
    b.writeln('rm -f /dev/wlan 2>/dev/null');
    b.writeln('mknod /dev/wlan c 1 3 2>/dev/null');
    b.writeln('chmod 666 /dev/wlan 2>/dev/null');
    b.writeln('restorecon /dev/wlan 2>/dev/null || '
        'chcon u:object_r:vendor_wlan_device:s0 /dev/wlan 2>/dev/null');
    // Restart the vendor wifi HAL + wificond so they re-enumerate with the adapter
    // up: a stale boot HAL only knows the unloaded internal chip ("no chip info"
    // -> createStaIface fails), and wificond caches a now-stale nl80211 family id.
    b.writeln('svc wifi disable 2>/dev/null');
    b.writeln('sleep 2');
    b.writeln('stop wificond 2>/dev/null || setprop ctl.stop wificond 2>/dev/null');
    b.writeln('stop vendor.wifi_hal_legacy 2>/dev/null || '
        'setprop ctl.stop vendor.wifi_hal_legacy 2>/dev/null');
    b.writeln('sleep 2');
    b.writeln('start vendor.wifi_hal_legacy 2>/dev/null || '
        'setprop ctl.start vendor.wifi_hal_legacy 2>/dev/null');
    b.writeln('sleep 1');
    b.writeln('start wificond 2>/dev/null || setprop ctl.start wificond 2>/dev/null');
    b.writeln('sleep 2');
    b.writeln('svc wifi enable 2>/dev/null');
    b.writeln('sleep 2');
    b.writeln('if ip link show "\$IF" >/dev/null 2>&1; then echo "OK_RECONFIG:\$IF"; else echo NO_IFACE; fi');
    return _shell.run(b.toString(), timeout: const Duration(seconds: 45));
  }

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
        // Same vendor-teardown + mac80211-first dance as switchToInject.
        final b = StringBuffer();
        b.writeln("if grep -q '^$_vendorWifi ' /proc/modules; then");
        b.writeln('  svc wifi disable 2>/dev/null');
        b.writeln('  sleep 2');
        b.writeln('  rmmod $_vendorWifi 2>/dev/null');
        b.writeln('fi');
        b.writeln('rmmod mac80211 2>/dev/null');
        b.writeln('rmmod cfg80211 2>/dev/null');
        b.writeln("insmod '$kModulesDir/cfg80211.ko' 2>&1");
        return _shell.run(b.toString());
      }
      return _shell.run(_insmodWithRetryScript(module));
    }
    return _shell.run("rmmod '${module.krName}' 2>&1");
  }

  /// rndis_host needs cdc_ether's usbnet_generic_cdc_bind / usbnet_cdc_zte_rx_fixup
  /// exports, but the vendor cdc_ether loaded at boot keeps them private (local
  /// symbols). Swap in our cdc_ether, which exports them: unload its holders +
  /// the vendor module, insmod ours, load rndis_host, then put the holders back
  /// (bound to ours now) so USB-Ethernet keeps working. Prints OK_RNDIS on success.
  Future<ShellResult> enableRndisHost() {
    final b = StringBuffer();
    b.writeln('HP=""');
    b.writeln('if [ -d /sys/module/cdc_ether ]; then');
    b.writeln('  for h in /sys/module/cdc_ether/holders/*; do');
    b.writeln('    [ -e "\$h" ] || continue');
    b.writeln('    n=\$(basename "\$h")');
    b.writeln('    p=\$(find $_vendorDlkmDir /vendor/lib/modules $kModulesDir '
        '-name "\$n.ko" 2>/dev/null | head -1)');
    b.writeln('    [ -n "\$p" ] && HP="\$HP \$p"');
    b.writeln('    rmmod "\$n" 2>/dev/null');
    b.writeln('  done');
    b.writeln('  rmmod cdc_ether 2>/dev/null');
    b.writeln('fi');
    b.writeln("insmod '$kModulesDir/cdc_ether.ko' 2>&1");
    b.writeln("insmod '$kModulesDir/rndis_host.ko' 2>&1");
    b.writeln('for p in \$HP; do [ -f "\$p" ] && insmod "\$p" 2>/dev/null; done');
    b.writeln("if grep -q '^rndis_host ' /proc/modules; then");
    b.writeln('  echo OK_RNDIS');
    b.writeln('else');
    b.writeln('  echo DMESG_TAIL:');
    b.writeln("  dmesg 2>/dev/null | grep -iE 'rndis|cdc_ether|Unknown symbol' | tail -n 12");
    b.writeln('fi');
    return _shell.run(b.toString(), timeout: const Duration(seconds: 40));
  }

  /// insmod several modules in dependency order (deepest dependency first),
  /// each with the same settle-retry as a single load; stops at the first that
  /// won't come up, reporting it as `CHAIN_FAIL:<name>`. The app resolves the
  /// order itself (see module_dependencies.dart) — there's no modules.dep on
  /// this device for `modprobe` to use.
  Future<ShellResult> loadChain(List<ModuleInfo> ordered) => _shell.run(
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
  Future<ShellResult> unloadChain(List<ModuleInfo> ordered) => _shell.run(
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

  /// Retries insmod a couple times a second apart — the wireless core can
  /// need a moment after cfg80211/mac80211 come up before it'll accept a new
  /// adapter. dmesg is fetched lazily via [moduleDmesg], not collected here,
  /// so a failed toggle doesn't block the next one.
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
    final r = await _shell.run(
      "dmesg 2>/dev/null | grep -iE '${module.krName}' | tail -n 20",
    );
    return r.stdout.trim();
  }

  /// Bundles last_kmsg (previous-boot panic), dmesg and logcat into one gzip
  /// archive inside [filesDir] (the app's private internal dir, so it dodges
  /// FUSE/FileProvider woes) and returns its path (null if it wasn't made).
  /// The archive is chowned + chcon'd to the app so the non-root app can read it.
  Future<String?> collectDebugLogs(String filesDir) async {
    final b = StringBuffer();
    b.writeln("BASE='$filesDir'");
    b.writeln(r'D="$BASE/pmm_logs"');
    b.writeln('rm -rf "\$D" 2>/dev/null');
    b.writeln('mkdir -p "\$D"');
    b.writeln('TS=\$(date +%Y%m%d-%H%M%S)');
    b.writeln('S=/data/local/tmp/pmm_dbg_\$TS');
    b.writeln('mkdir -p "\$S"');
    b.writeln('{ echo "collected \$TS"; getprop ro.build.version.incremental; uname -a; } > "\$S/info.txt" 2>&1');
    b.writeln('cat /data/vendor/diag/last_kmsg > "\$S/last_kmsg.txt" 2>/dev/null || echo "(no last_kmsg)" > "\$S/last_kmsg.txt"');
    b.writeln('dmesg > "\$S/dmesg.txt" 2>/dev/null || echo "(dmesg unavailable)" > "\$S/dmesg.txt"');
    b.writeln('logcat -d -b all -v time > "\$S/logcat.txt" 2>/dev/null || echo "(logcat unavailable)" > "\$S/logcat.txt"');
    b.writeln('OUT="\$D/picters-logs-\$TS.tar.gz"');
    b.writeln('tar -czf "\$OUT" -C "\$S" . 2>/dev/null');
    b.writeln('rm -rf "\$S"');
    // Hand the dir+archive to the app: copy its own data dir's owner + SELinux
    // context (app_data_file:s0:c...) so the non-root app can open the file.
    b.writeln("A=/data/data/com.picters.modulesmanager");
    b.writeln(r'O=$(stat -c %u "$A" 2>/dev/null); G=$(stat -c %g "$A" 2>/dev/null); C=$(stat -c %C "$A" 2>/dev/null)');
    b.writeln(r'[ -n "$O" ] && chown -R "$O:$G" "$D" 2>/dev/null');
    b.writeln(r'[ -n "$C" ] && chcon -R "$C" "$D" 2>/dev/null');
    b.writeln('chmod 660 "\$OUT" 2>/dev/null');
    b.writeln('echo "\$OUT"');
    final r = await _shell.run(b.toString(), timeout: const Duration(seconds: 60));
    if (!r.ok) return null;
    final path = r.stdout.trim().split('\n').last.trim();
    return path.endsWith('.tar.gz') ? path : null;
  }

  /// Deletes a collected archive — the "discard" path when the user is done.
  Future<void> deleteDebugLogs(String path) =>
      _shell.run("rm -f '$path'");

  // ── Kernel / OOT-modules update delivery ────────────────────────────────

  static const String _modProp =
      '/data/adb/modules/picters-modules-pack/module.prop';

  /// The versionCode of the currently-installed modules pack (module.prop),
  /// used to gate features on a matching kernel. 0 if not installed/unstamped.
  Future<int> installedModulesVersionCode() async {
    final r = await _shell.run(
      "grep '^versionCode=' '$_modProp' 2>/dev/null | head -1 | cut -d= -f2",
    );
    return int.tryParse(r.stdout.trim()) ?? 0;
  }

  /// Copies a downloaded zip into /sdcard/Download so the user can flash it
  /// themselves in KernelSU/Magisk. Uses root since scoped storage blocks it.
  Future<bool> copyToDownloads(String srcPath, String name) async {
    final r = await _shell.run(
      "mkdir -p /sdcard/Download && cp '$srcPath' '/sdcard/Download/$name' && "
      "chmod 664 '/sdcard/Download/$name' && echo OK",
    );
    return r.stdout.contains('OK');
  }

  /// Installs the OOT-modules zip as a KernelSU (or Magisk) module — the safe
  /// auto path (no boot flashing). A reboot is required to activate it.
  Future<ShellResult> installModuleZip(String zipPath) => _shell.run(
        "if command -v ksud >/dev/null 2>&1; then ksud module install '$zipPath' 2>&1; "
        "elif command -v magisk >/dev/null 2>&1; then magisk --install-module '$zipPath' 2>&1; "
        "else echo NO_MODULE_MANAGER; fi",
        timeout: const Duration(seconds: 90),
      );

  /// The running kernel's release string (`uname -r`) — the app checks it for
  /// the "picters" tag to warn when it's running on a foreign kernel.
  Future<String> kernelRelease() async {
    final r = await _shell.run('uname -r 2>/dev/null');
    return r.stdout.trim();
  }

  /// The device-identity props the updater gates on (one round-trip). The
  /// kernel + OOT modules are built for the Xiaomi 17 series' sm8850 SoC, so
  /// this decides whether it's safe to offer an update at all.
  Future<DeviceIdentity> deviceIdentity() async {
    final r = await _shell.run(
      'echo "SOC:\$(getprop ro.soc.model)"; '
      'echo "BRAND:\$(getprop ro.product.brand)"; '
      'echo "MARKET:\$(getprop ro.product.marketname)"',
    );
    return parseDeviceIdentity(r.stdout);
  }

  /// A UUID that changes on every boot — lets the app tell whether a reboot has
  /// happened since a pending update was installed.
  Future<String> currentBootId() async {
    final r = await _shell.run('cat /proc/sys/kernel/random/boot_id 2>/dev/null');
    return r.stdout.trim();
  }

  /// (isAbDevice, activeSlotSuffix). isAb is true only when both boot_a and
  /// boot_b exist; activeSlot is "_a"/"_b" (empty on non-slot devices).
  Future<(bool, String)> slotInfo() async {
    final r = await _shell.run(
      'A=\$(getprop ro.boot.slot_suffix); '
      'if ls /dev/block/by-name/boot_a >/dev/null 2>&1 && '
      'ls /dev/block/by-name/boot_b >/dev/null 2>&1; then echo "AB \$A"; '
      'else echo "SINGLE \$A"; fi',
    );
    final parts = r.stdout.trim().split(RegExp(r'\s+'));
    final ab = parts.isNotEmpty && parts.first == 'AB';
    final slot = parts.length > 1 ? parts[1].trim() : '';
    return (ab, slot);
  }

  /// Flashes an AnyKernel3 kernel zip to a boot slot via root (bootmode). With
  /// [inactiveSlot] true, AK3's slot_select=inactive targets the OTHER slot;
  /// otherwise it writes the active slot. Success = the run prints AK3_EXIT:0
  /// and no AK3 "abort". Never touches the boot image on a plain module update.
  Future<ShellResult> flashKernelZip(String zipPath,
      {required bool inactiveSlot}) {
    final b = StringBuffer();
    b.writeln('AK=/data/local/tmp/pmm_ak3');
    b.writeln('rm -rf "\$AK"; mkdir -p "\$AK"');
    b.writeln(
        'if ! unzip -o "$zipPath" -d "\$AK" >/dev/null 2>&1; then echo AK3_UNZIP_FAIL; exit 0; fi');
    b.writeln('UB="\$AK/META-INF/com/google/android/update-binary"');
    b.writeln('[ -f "\$UB" ] || { echo AK3_NO_UB; exit 0; }');
    b.writeln('export AKHOME="\$AK"');
    if (inactiveSlot) b.writeln('export slot_select=inactive');
    b.writeln('sh "\$UB" 3 1 "$zipPath" 2>&1');
    b.writeln('echo "AK3_EXIT:\$?"');
    b.writeln('rm -rf "\$AK"');
    return _shell.run(b.toString(), timeout: const Duration(seconds: 180));
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
