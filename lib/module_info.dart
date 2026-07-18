import 'usb_devices.dart';

/// A single OOT `.ko` driver staged under /system/lib/modules.
class ModuleInfo {
  const ModuleInfo({
    required this.name,
    required this.loaded,
    required this.isWifiClass,
  });

  /// Filename base as it sits on disk (e.g. "rtl8192c-common"), dashes intact.
  final String name;
  final bool loaded;

  /// True for cfg80211/mac80211 and every Wi-Fi chipset driver.
  final bool isWifiClass;

  /// The kernel normalizes '-' to '_' when it registers a module, so this is
  /// what shows up in /proc/modules and what rmmod expects — insmod still takes
  /// the on-disk path (with dashes).
  String get krName => name.replaceAll('-', '_');
}

/// Which Wi-Fi stack is live. The whole point of the main screen: one switch
/// between the stock vendor stack and our injection stack.
enum WifiMode {
  /// Vendor qca_cld3 loaded — internal Wi-Fi works, injection off.
  stock,

  /// Our kernel cfg80211(+mac80211) loaded, vendor torn down — injection on.
  inject,

  /// Neither loaded (e.g. mid-transition or fully unloaded).
  off,
}

/// A live wireless netdev (`wlanX`) as sysfs reports it — what the Reconfigure
/// flow targets when handing an adapter to the Android framework.
class WifiInterface {
  const WifiInterface({
    required this.name,
    required this.driver,
    required this.up,
    required this.monitor,
  });

  /// Interface name, e.g. "wlan0", "wlan1".
  final String name;

  /// Bound kernel driver (e.g. "88XXau"), empty if none is attached.
  final String driver;

  /// operstate is "up" (vs down/dormant/unknown).
  final bool up;

  /// ARPHRD type is radiotap (802.11 monitor) rather than plain ether.
  final bool monitor;
}

/// Everything one root scan gathers, in one immutable snapshot.
class SystemState {
  const SystemState({
    required this.modules,
    required this.adapters,
    required this.interfaces,
    required this.wifiMode,
    required this.cfgLoaded,
    required this.macLoaded,
    required this.vendorWifiLoaded,
    required this.modulesDirExists,
  });

  final List<ModuleInfo> modules;
  final List<DetectedAdapter> adapters;
  final List<WifiInterface> interfaces;
  final WifiMode wifiMode;
  final bool cfgLoaded;
  final bool macLoaded;
  final bool vendorWifiLoaded;
  final bool modulesDirExists;

  static const empty = SystemState(
    modules: [],
    adapters: [],
    interfaces: [],
    wifiMode: WifiMode.stock,
    cfgLoaded: false,
    macLoaded: false,
    vendorWifiLoaded: true,
    modulesDirExists: false,
  );

  List<ModuleInfo> get wifiModules =>
      modules.where((m) => m.isWifiClass).toList();
  List<ModuleInfo> get otherModules =>
      modules.where((m) => !m.isWifiClass).toList();

  /// Cheap fingerprint so the UI can skip rebuilds when a 1s poll changed
  /// nothing.
  String get fingerprint {
    final mods = modules.map((m) => '${m.name}:${m.loaded ? 1 : 0}').join(',');
    final adap = adapters
        .map((a) =>
            '${a.device.idPair}:${a.device.driver}:${a.recognized ? a.match!.driver : "?"}')
        .join(',');
    final ifs = interfaces
        .map((i) => '${i.name}:${i.driver}:${i.up ? 1 : 0}:${i.monitor ? 1 : 0}')
        .join(',');
    return '$wifiMode|$mods|$adap|$ifs|$modulesDirExists';
  }
}
