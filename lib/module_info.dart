/// A single OOT `.ko` driver staged under /system/lib/modules by the
/// nethunter-oot-modules KernelSU/Magisk module.
class ModuleInfo {
  const ModuleInfo({
    required this.name,
    required this.loaded,
    required this.isWifiClass,
  });

  /// Filename base as it sits on disk (e.g. "rtl8192c-common"), dashes intact.
  final String name;

  final bool loaded;

  /// True for cfg80211/mac80211 and every Wi-Fi chipset driver — these need the
  /// vendor-stack teardown + kernel cfg80211/mac80211 prereqs before insmod.
  final bool isWifiClass;

  /// The kernel normalizes '-' to '_' when it registers a module, so this is
  /// what actually shows up in /proc/modules and what rmmod expects — insmod
  /// still takes the on-disk path (with dashes) as its argument.
  String get krName => name.replaceAll('-', '_');

  ModuleInfo copyWith({bool? loaded}) => ModuleInfo(
        name: name,
        loaded: loaded ?? this.loaded,
        isWifiClass: isWifiClass,
      );
}

class ScanResult {
  const ScanResult({
    required this.modules,
    required this.vendorWifiLoaded,
    required this.modulesDirExists,
  });

  final List<ModuleInfo> modules;

  /// True while the stock qca_cld3 vendor Wi-Fi stack is loaded, i.e. injection
  /// mode is NOT active. Once a kernel Wi-Fi driver tears it down it can only
  /// come back via reboot (Qualcomm firmware limitation).
  final bool vendorWifiLoaded;

  final bool modulesDirExists;
}
