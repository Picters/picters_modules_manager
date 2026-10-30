import 'app_controller.dart';
import 'battery_reading.dart';
import 'iw_repository.dart';
import 'module_info.dart';
import 'module_repository.dart';
import 'perf_controller.dart';
import 'perf_info.dart';
import 'perf_repository.dart';
import 'root_shell.dart';
import 'usb_devices.dart';

/// Uses the real controllers and screens, with an entirely in-memory device.
/// No demo action reaches a native channel, shell, network or persistent file.
AppController createPreviewController() {
  final device = PreviewDevice();
  return AppController(
    PreviewModuleRepository(device),
    perfController: PerfController(PreviewPerfRepository()),
    iwRepository: PreviewIwRepository(device),
    isPreview: true,
  );
}

class PreviewDevice {
  WifiMode wifiMode = WifiMode.stock;
  bool bootLoad = true;
  bool externalUp = true;
  bool monitor = true;
  String region = '00';
  int txPower = 20;
  final Map<String, int> savedTx = {};
  final Map<String, bool> modules = {
    'cfg80211': false,
    'mac80211': false,
    '88XXau': false,
    '8188eu': false,
    '8814au': false,
    '88x2bu': false,
    'ath': false,
    'ath9k_hw': false,
    'ath9k_common': false,
    'ath9k_htc': false,
    'mt7601u': false,
    'rtl8187': false,
    'btusb': true,
    'cdc_acm': true,
    'cdc_ether': true,
    'cp210x': false,
    'ftdi_sio': false,
    'gs_usb': false,
    'hid': true,
    'hid-generic': true,
    'ntfs3': false,
    'nfs': false,
    'rndis_host': false,
    'rtl2832': false,
    'rtl2832_sdr': false,
    'usbnet': true,
  };

  List<WifiInterface> get interfaces => [
    if (wifiMode == WifiMode.stock)
      const WifiInterface(
        name: 'wlan0',
        driver: 'qca_cld3_peach_v2',
        up: true,
        monitor: false,
        mac: '48:6b:2c:45:18:2a',
      ),
    if (wifiMode == WifiMode.inject && modules['88XXau'] == true)
      WifiInterface(
        name: 'wlan1',
        driver: '88XXau',
        up: externalUp,
        monitor: monitor,
        usbPath: '1-1',
        mac: '00:c0:ca:12:34:56',
      ),
  ];
}

const _ok = ShellResult(0, 'OK');
Future<void> _actionDelay() =>
    Future<void>.delayed(const Duration(milliseconds: 180));

class PreviewModuleRepository extends ModuleRepository {
  PreviewModuleRepository(this.device);
  final PreviewDevice device;

  @override
  Future<SystemState> scan() async => SystemState(
    battery: const BatteryReading(
      percent: 72,
      temperatureC: 36.8,
      currentMa: 2200,
      voltageV: 4.18,
      connected: true,
      charging: true,
    ),
    modules: [
      for (final entry in device.modules.entries)
        ModuleInfo(
          name: entry.key,
          loaded: entry.value,
          isWifiClass: kWifiClassModules.contains(entry.key),
        ),
    ],
    adapters: [
      DetectedAdapter(
        device: UsbDevice(
          vendorId: '0bda',
          productId: '8812',
          manufacturer: 'ALFA',
          product: 'AWUS036ACH',
          driver: device.modules['88XXau'] == true ? '88XXau' : '',
          sysfsName: '1-1',
        ),
        match: const KnownAdapter(
          '0bda',
          '8812',
          'Realtek RTL8812AU',
          '88XXau',
        ),
      ),
      const DetectedAdapter(
        device: UsbDevice(
          vendorId: '10c4',
          productId: 'ea60',
          manufacturer: 'Silicon Labs',
          product: 'CP2102 USB to UART',
          sysfsName: '1-2',
        ),
        match: null,
      ),
    ],
    interfaces: device.interfaces,
    wifiMode: device.wifiMode,
    cfgLoaded: device.modules['cfg80211'] == true,
    macLoaded: device.modules['mac80211'] == true,
    vendorWifiLoaded: device.wifiMode == WifiMode.stock,
    modulesDirExists: true,
  );

  @override
  Future<bool> bootLoadEnabled() async => device.bootLoad;
  @override
  Future<void> setBootLoadEnabled(bool enabled) async {
    await _actionDelay();
    device.bootLoad = enabled;
  }

  @override
  Future<bool> hidePerformance() async => false;
  @override
  Future<void> setHidePerformance(bool hide) async {}

  @override
  Future<ShellResult> switchToInject(List<ModuleInfo> modules) async {
    await _actionDelay();
    device.wifiMode = WifiMode.inject;
    device.modules['cfg80211'] = true;
    device.modules['mac80211'] = true;
    return const ShellResult(0, 'OK_INJECT');
  }

  @override
  Future<ShellResult> switchToStock(List<ModuleInfo> modules) async {
    await _actionDelay();
    for (final name in kWifiClassModules) {
      if (device.modules.containsKey(name)) device.modules[name] = false;
    }
    device.wifiMode = WifiMode.stock;
    return const ShellResult(0, 'OK_STOCK');
  }

  @override
  Future<ShellResult> setLoaded(ModuleInfo module, bool wantLoaded) async {
    await _actionDelay();
    if (wantLoaded && module.name == 'cfg80211') {
      device.wifiMode = WifiMode.inject;
    } else if (wantLoaded &&
        module.isWifiClass &&
        device.wifiMode != WifiMode.inject) {
      throw const ModulePrecondition('Enable Inject mode first.');
    }
    device.modules[module.name] = wantLoaded;
    if (!wantLoaded &&
        module.name == 'cfg80211' &&
        device.wifiMode == WifiMode.inject) {
      device.wifiMode = WifiMode.off;
    }
    return _ok;
  }

  @override
  Future<ShellResult> enableRndisHost() async {
    await _actionDelay();
    device.modules['cdc_ether'] = true;
    device.modules['rndis_host'] = true;
    return const ShellResult(0, 'OK_RNDIS');
  }

  @override
  Future<ShellResult> loadChain(List<ModuleInfo> ordered) async {
    for (final module in ordered) {
      await setLoaded(module, true);
    }
    return const ShellResult(0, 'OK_CHAIN');
  }

  @override
  Future<ShellResult> unloadChain(List<ModuleInfo> ordered) async {
    for (final module in ordered) {
      await setLoaded(module, false);
    }
    return const ShellResult(0, 'OK_CHAIN');
  }

  @override
  Future<ShellResult> reconfigureManaged({
    required String chipsetDriver,
    required String iface,
    bool reloadDriver = true,
  }) async {
    await _actionDelay();
    device.monitor = false;
    device.externalUp = true;
    return const ShellResult(0, 'OK_RECONFIG:wlan1');
  }

  @override
  Future<void> reboot() async {}
  @override
  Future<String> moduleDmesg(ModuleInfo module) async =>
      '[Preview] ${module.name}: simulated driver state; no device commands executed.';
  @override
  Future<String?> collectDebugLogs(String filesDir) async => null;
  @override
  Future<void> deleteDebugLogs(String path) async {}
  @override
  Future<int> installedModulesVersionCode() async => 610030027;
  @override
  Future<String?> installedReleaseChannel() async => 'A16';
  @override
  Future<String> kernelRelease() async =>
      '6.12.23-android16-picters-ReSuki-preview';
  @override
  Future<DeviceIdentity> deviceIdentity() async => const DeviceIdentity(
    socModel: 'SM8850',
    brand: 'Xiaomi',
    marketName: 'Xiaomi 17',
  );
}

class PreviewPerfRepository extends PerfRepository {
  PerfProfile _profile = PerfProfile.full;
  bool _persist = false;
  bool _locked = false;
  // Frequency tables from the user's Xiaomi 17 diagnostic capture (SM8850).
  static const _gpuFreqs = [
    160000000,
    191000000,
    222000000,
    282000000,
    342000000,
    382000000,
    422000000,
    461000000,
    500000000,
    578000000,
    646000000,
    726000000,
    826000000,
    902000000,
    1000000000,
    1050000000,
    1100000000,
    1200000000,
  ];
  static const _perfFreqs = [
    384000,
    537600,
    691200,
    787200,
    883200,
    998400,
    1113600,
    1228800,
    1324800,
    1440000,
    1555200,
    1670400,
    1785600,
    1900800,
    1996800,
    2112000,
    2227200,
    2361600,
    2496000,
    2611200,
    2745600,
    2899200,
    3033600,
    3187200,
    3302400,
    3398400,
    3513600,
    3628800,
  ];
  // cpuinfo_max_freq also exposes the 4.608 GHz boost ceiling. The exported
  // scaling table in this snapshot ends at 4.3968 GHz; do not invent OPPs.
  static const _primeFreqs = [
    768000,
    883200,
    1017600,
    1132800,
    1267200,
    1382400,
    1497600,
    1632000,
    1747200,
    1862400,
    1977600,
    2112000,
    2227200,
    2438400,
    2668800,
    2880000,
    3129600,
    3398400,
    3648000,
    3763200,
    3859200,
    3974400,
    4070400,
    4185600,
    4262400,
    4339200,
    4396800,
  ];

  @override
  Future<PerfState> scan() async {
    final gaming = _profile == PerfProfile.gaming;
    CpuCluster cluster(
      String policy,
      List<int> cpus,
      int max,
      PerfDomain domain,
    ) {
      final frequencies = domain == PerfDomain.primeCpu
          ? _primeFreqs
          : _perfFreqs;
      final cap = cappedMax(_profile, domain, max, frequencies);
      return CpuCluster(
        policy: policy,
        cpus: cpus,
        maxHardware: max,
        scalingMax: cap,
        availableFreqs: frequencies,
        governor: gaming ? 'performance' : 'schedutil',
        availableGovernors: const ['schedutil', 'performance'],
        governorWritable: true,
        scalingMin: _locked ? cap : frequencies.first,
        minWritable: true,
      );
    }

    final gpuCap = cappedMax(
      _profile,
      PerfDomain.gpu,
      _gpuFreqs.last,
      _gpuFreqs,
    );
    return PerfState(
      clusters: [
        cluster('policy0', [0, 1, 2, 3, 4, 5], 3628800, PerfDomain.perfCpu),
        cluster('policy6', [6, 7], 4608000, PerfDomain.primeCpu),
      ],
      gpu: GpuInfo(
        availableFreqs: _gpuFreqs,
        currentMax: gpuCap,
        stockMax: _gpuFreqs.last,
        governor: gaming ? 'performance' : 'msm-adreno-tz',
        governorNode: '/sys/class/kgsl/kgsl-3d0/devfreq/governor',
        availableGovernors: const ['msm-adreno-tz', 'performance'],
        governorWritable: true,
        currentMin: _locked ? gpuCap : _gpuFreqs.first,
        minNode: '/sys/class/kgsl/kgsl-3d0/devfreq/min_freq',
        minWritable: true,
      ),
      profile: _profile,
      persistOnBoot: _persist,
      bootApplySupported: true,
      kernelCapsSupported: true,
      frequenciesLocked: _locked,
      gamingActive: gaming,
      lockActive: _locked,
      advancedBootSupported: true,
    );
  }

  @override
  Future<ShellResult> applyProfile({
    required PerfProfile profile,
    required PerfState state,
    required bool persistOnBoot,
  }) async {
    await _actionDelay();
    _profile = profile;
    _persist = persistOnBoot;
    return const ShellResult(0, 'OK_PERF');
  }

  @override
  Future<ShellResult> setFrequencyLock({
    required bool locked,
    required PerfState state,
    required bool persistOnBoot,
  }) async {
    await _actionDelay();
    _locked = locked;
    _persist = persistOnBoot;
    return const ShellResult(0, 'OK_PERF');
  }
}

class PreviewIwRepository extends IwRepository {
  PreviewIwRepository(this.device);
  final PreviewDevice device;

  @override
  Future<String?> ensureBinary() async => 'preview://iw';
  @override
  Future<IwInfo?> query(String iface) async => IwInfo(
    txPowerDbm: device.txPower.toDouble(),
    regDomain: device.region,
    regDomainLocked: false,
    type: device.monitor ? 'monitor' : 'managed',
  );
  @override
  Future<ShellResult> setMode({
    required String iface,
    required bool monitor,
  }) async {
    await _actionDelay();
    device.monitor = monitor;
    return const ShellResult(0, 'OK_MODE');
  }

  @override
  Future<ShellResult> setLinkUp({
    required String iface,
    required bool up,
  }) async {
    device.externalUp = up;
    return const ShellResult(0, 'OK_LINK');
  }

  @override
  Future<ShellResult> setRegulatoryDomain(String alpha2) async {
    device.region = alpha2;
    return const ShellResult(0, 'OK_REG');
  }

  @override
  Future<ShellResult> setTxPower({
    required String iface,
    required int dbm,
  }) async {
    device.txPower = dbm;
    return const ShellResult(0, 'OK_TXPOWER');
  }

  @override
  Future<void> preloadTx() async {}
  @override
  int? lastSetTxSync(String driver) => device.savedTx[driver];
  @override
  int? stockTxSync(String driver) => 20;
  @override
  Future<int?> stockTx(String driver) async => 20;
  @override
  Future<void> recordStockTx(String driver, int dbm) async {}
  @override
  Future<int?> lastSetTx(String driver) async => device.savedTx[driver];
  @override
  Future<void> recordSetTx(String driver, int dbm) async {
    device.savedTx[driver] = dbm;
  }
}
