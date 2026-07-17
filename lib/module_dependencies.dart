/// Module dependency graph and load/unload order resolution.
///
/// `insmod` doesn't pull in dependencies and there's no `modules.dep` on this
/// device, so we resolve load order ourselves from each module's `modinfo -F
/// depends` output.
library;

/// cfg80211 + mac80211 — only ever loaded via the Overview Stock/Inject
/// switch, never as an ordinary dependency.
const Set<String> kInjectCore = {'cfg80211', 'mac80211'};

/// Direct dependencies per shipped module. Deps not in this project's `.ko`
/// set are vendor/kernel-builtin and get filtered out at resolve time.
const Map<String, List<String>> kModuleDeps = {
  // ── Wi-Fi: Realtek rtlwifi family ──
  'rtlwifi': ['cfg80211', 'rfkill', 'mac80211'],
  'rtl_usb': ['rtlwifi', 'mac80211'],
  'rtl8192cu': ['rtlwifi', 'rtl8192c-common', 'rtl_usb', 'mac80211'],
  'rtl8192c-common': ['rtlwifi'],
  'rtl8187': ['mac80211', 'eeprom_93cx6', 'cfg80211', 'rfkill'],
  'rtl8xxxu': ['cfg80211', 'mac80211'],
  // ── Wi-Fi: Ralink rt2x00 family ──
  'rt2x00lib': ['mac80211', 'cfg80211', 'rfkill'],
  'rt2x00usb': ['rt2x00lib', 'mac80211'],
  'rt2800lib': ['rt2x00lib', 'mac80211'],
  'rt2800usb': ['rt2x00usb', 'rt2800lib', 'rt2x00lib', 'mac80211'],
  'rt73usb': ['rt2x00usb', 'rt2x00lib', 'crc-itu-t', 'mac80211'],
  'rt2500usb': ['rt2x00usb', 'rt2x00lib', 'mac80211'],
  // ── Wi-Fi: Atheros ──
  'ath': ['cfg80211'],
  'ath9k_hw': ['ath'],
  'ath9k_common': ['cfg80211', 'ath9k_hw', 'ath'],
  'ath9k_htc': ['mac80211', 'ath9k_hw', 'ath', 'ath9k_common', 'cfg80211', 'rfkill'],
  'ath6kl_core': ['cfg80211'],
  'ath6kl_usb': ['ath6kl_core'],
  'carl9170': ['mac80211', 'ath', 'cfg80211'],
  // ── Wi-Fi: other USB chipsets ──
  'mt7601u': ['mac80211', 'cfg80211'],
  'zd1211rw': ['cfg80211', 'mac80211'],
  '88XXau': ['cfg80211'],
  '8188eu': ['cfg80211'],
  '8814au': ['cfg80211'],
  '88x2bu': ['cfg80211'],
  // ── Bluetooth (bluetooth core is builtin) ──
  'btusb': ['bluetooth', 'btintel', 'btbcm', 'btrtl'],
  'btrtl': ['bluetooth'],
  'btintel': ['bluetooth'],
  'btbcm': ['bluetooth'],
  'hci_uart': ['bluetooth', 'btbcm', 'pwrseq-core', 'btqca'],
  'bnep': ['bluetooth'],
  'rfcomm': ['bluetooth'],
  'hidp': ['bluetooth'],
  'bfusb': ['bluetooth'],
  'bpa10x': ['bluetooth'],
  'bcm203x': ['bluetooth'],
  // ── SDR / DVB ──
  'dvb_usb_v2': ['dvb-core'],
  'dvb-usb-rtl28xxu': ['dvb_usb_v2'],
  'rtl2830': ['i2c-mux'],
  'rtl2832': ['i2c-mux'],
  'si2168': ['i2c-mux'],
  // ── CAN ──
  'can-raw': ['can'],
  'can-bcm': ['can'],
  'can-gw': ['can'],
  'vcan': ['can-dev'],
  'slcan': ['can-dev'],
  'hi311x': ['can-dev'],
  'mcp251x': ['can-dev'],
  'ems_usb': ['can-dev'],
  'esd_usb': ['can-dev'],
  'gs_usb': ['can-dev'],
  'kvaser_usb': ['can-dev'],
  'peak_usb': ['can-dev'],
  'usb_8dev': ['can-dev'],
  // ── USB Ethernet (usbnet/mii builtin) ──
  'r8152': ['mii'],
  'cdc_ether': ['usbnet'],
  'cdc_subset': ['usbnet'],
  'rndis_host': ['cdc_ether', 'usbnet'],
  // ── USB serial ──
  'cp210x': ['usbserial'],
  'ch341': ['usbserial'],
  'ftdi_sio': ['usbserial'],
  'pl2303': ['usbserial'],
};

/// What loading a given module needs right now, given the live state.
class DependencyPlan {
  const DependencyPlan({required this.needsInjectMode, required this.toLoad});

  /// The module (or one of its deps) needs cfg80211/mac80211 but Inject mode
  /// isn't active — the user has to enable it on the Overview screen first.
  final bool needsInjectMode;

  /// Other shipped modules that must be insmod'd first, already in load order
  /// (deepest dependency first). Excludes the target itself and anything
  /// already loaded. Empty when the module can load on its own.
  final List<String> toLoad;

  bool get hasMissingDeps => toLoad.isNotEmpty;
  bool get ready => !needsInjectMode && toLoad.isEmpty;
}

/// Resolves what has to happen before [target] can be insmod'd.
///
/// [available] is the set of on-disk module basenames this build ships;
/// [loaded] is the subset currently resident. Dependencies that aren't in
/// [available] are treated as kernel-builtin and ignored (their symbols are
/// always present). cfg80211/mac80211 are handled via [needsInjectMode]
/// rather than added to [DependencyPlan.toLoad].
DependencyPlan planModuleLoad({
  required String target,
  required Set<String> available,
  required Set<String> loaded,
  required bool injectActive,
}) {
  var needsCore = false;
  final order = <String>[];
  final seen = <String>{};

  void visit(String name) {
    if (!seen.add(name)) return;
    for (final dep in kModuleDeps[name] ?? const <String>[]) {
      if (kInjectCore.contains(dep)) {
        if (!injectActive) needsCore = true;
        continue;
      }
      if (!available.contains(dep)) continue; // builtin / vendor-provided
      visit(dep);
      if (!loaded.contains(dep) && !order.contains(dep)) order.add(dep);
    }
  }

  visit(target);
  return DependencyPlan(needsInjectMode: needsCore, toLoad: order);
}

/// Currently-loaded modules that (directly or transitively) depend on [target],
/// i.e. the ones `rmmod <target>` would fail on with "Module ... is in use".
/// Returned in unload order — outermost users first — so removing them in
/// sequence, then [target], always succeeds. [target] itself is not included.
List<String> loadedDependents({
  required String target,
  required Set<String> available,
  required Set<String> loaded,
}) {
  bool dependsOn(String module, String needle) {
    final seen = <String>{};
    bool dfs(String m) {
      for (final dep in kModuleDeps[m] ?? const <String>[]) {
        if (dep == needle) return true;
        if (available.contains(dep) && seen.add(dep) && dfs(dep)) return true;
      }
      return false;
    }

    return dfs(module);
  }

  final dependents =
      loaded.where((m) => m != target && dependsOn(m, target)).toSet();

  // Peel off, layer by layer, the modules nothing else still-listed depends on
  // — those are safe to rmmod first.
  final ordered = <String>[];
  final remaining = {...dependents};
  while (remaining.isNotEmpty) {
    final layer = remaining
        .where((m) => !remaining.any((other) =>
            other != m && (kModuleDeps[other] ?? const []).contains(m)))
        .toList();
    if (layer.isEmpty) {
      ordered.addAll(remaining); // cycle guard (shouldn't happen)
      break;
    }
    ordered.addAll(layer);
    remaining.removeAll(layer);
  }
  return ordered;
}
