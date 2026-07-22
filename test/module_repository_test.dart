import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/module_info.dart';
import 'package:picters_modules_manager/module_repository.dart';
import 'package:picters_modules_manager/root_shell.dart';
import 'package:picters_modules_manager/usb_devices.dart';

/// A [RootRunner] that records every script it's handed and replies with a
/// canned [ShellResult] — so we can assert on the exact shell the repository
/// emits and on how it parses a stubbed reply, with no device in the loop.
class FakeRootRunner implements RootRunner {
  FakeRootRunner([this.responder]);

  /// Maps a script to the result it should return; null → an empty success.
  final ShellResult Function(String script)? responder;

  final List<String> scripts = [];
  String get lastScript => scripts.last;

  @override
  Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    scripts.add(script);
    return responder?.call(script) ?? const ShellResult(0, '');
  }
}

/// Builds the combined-scan stdout the real device would produce, framed by the
/// same section markers [ModuleRepository.scan] splits on.
String scanOutput({
  required List<String> koFiles,
  required List<String> procModules,
  List<String> usb = const [],
  List<String> iface = const [],
  bool dirOk = true,
}) {
  // Section headers, built exactly as ModuleRepository.scan emits them: the USB
  // and IFACE headers are `${proc}_USB` / `${proc}_IFACE`, so proc's trailing
  // `___` plus the `_` yields four underscores before the suffix.
  const proc = '___PMM_PROC___';
  final b = StringBuffer()
    ..writeln('___PMM_MODS___');
  if (dirOk) b.writeln('DIR_OK');
  for (final f in koFiles) {
    b.writeln('/system/lib/modules/$f');
  }
  b.writeln(proc);
  for (final m in procModules) {
    b.writeln('$m 16384 0 - Live 0x0000000000000000');
  }
  b.writeln('${proc}_USB');
  for (final u in usb) {
    b.writeln('$usbMarker$u');
  }
  b.writeln('${proc}_IFACE');
  for (final i in iface) {
    b.writeln('$ifaceMarker$i');
  }
  return b.toString();
}

void main() {
  group('scan', () {
    test('one round-trip; parses modules, adapters and interfaces', () async {
      final fake = FakeRootRunner((_) => ShellResult(
            0,
            scanOutput(
              koFiles: ['cfg80211.ko', 'mac80211.ko', '88XXau.ko', 'btusb.ko'],
              procModules: ['cfg80211', 'mac80211', '88XXau'],
              usb: ['0bda|8812|Realtek|RTL8812AU|00|88XXau'],
              iface: ['wlan0|88XXau|0x1003|803'],
            ),
          ));
      final state = await ModuleRepository(fake).scan();

      expect(fake.scripts, hasLength(1)); // stays a single su round-trip
      expect(state.modulesDirExists, isTrue);
      expect(state.wifiMode, WifiMode.inject); // cfg80211 up, vendor down

      ModuleInfo mod(String n) => state.modules.firstWhere((m) => m.name == n);
      expect(mod('cfg80211').loaded, isTrue);
      expect(mod('88XXau').loaded, isTrue);
      expect(mod('btusb').loaded, isFalse);

      expect(state.adapters, hasLength(1));
      expect(state.adapters.first.match!.driver, '88XXau');
      expect(state.interfaces.single.name, 'wlan0');
      expect(state.interfaces.single.monitor, isTrue); // ARPHRD 803
      expect(state.interfaces.single.up, isTrue); // IFF_UP set (0x1003)
    });

    test('vendor qca_cld3 loaded reads as Stock mode', () async {
      final fake = FakeRootRunner((_) => ShellResult(
            0,
            scanOutput(
              koFiles: ['cfg80211.ko'],
              procModules: ['qca_cld3_peach_v2', 'cfg80211', 'mac80211'],
            ),
          ));
      expect((await ModuleRepository(fake).scan()).wifiMode, WifiMode.stock);
    });

    test('neither stack loaded reads as Off', () async {
      final fake = FakeRootRunner((_) => ShellResult(
            0,
            scanOutput(koFiles: ['cfg80211.ko'], procModules: ['btusb']),
          ));
      expect((await ModuleRepository(fake).scan()).wifiMode, WifiMode.off);
    });

    test('dash-named module matches its underscore /proc name as loaded', () async {
      final fake = FakeRootRunner((_) => ShellResult(
            0,
            scanOutput(
              koFiles: ['rtl8192c-common.ko'],
              procModules: ['rtl8192c_common'],
            ),
          ));
      final state = await ModuleRepository(fake).scan();
      expect(state.modules.single.name, 'rtl8192c-common');
      expect(state.modules.single.loaded, isTrue);
    });
  });

  group('boot-load flag', () {
    test('bootLoadEnabled reads Y/N and probes the persisted flag path', () async {
      final yes = FakeRootRunner((_) => const ShellResult(0, 'Y'));
      expect(await ModuleRepository(yes).bootLoadEnabled(), isTrue);
      expect(yes.lastScript, contains(kBootLoadFlag));

      final no = FakeRootRunner((_) => const ShellResult(0, 'N'));
      expect(await ModuleRepository(no).bootLoadEnabled(), isFalse);
    });

    test('setBootLoadEnabled creates the flag on, removes it off', () async {
      final on = FakeRootRunner();
      await ModuleRepository(on).setBootLoadEnabled(true);
      expect(on.lastScript, contains('touch'));
      expect(on.lastScript, contains(kBootConfigDir));

      final off = FakeRootRunner();
      await ModuleRepository(off).setBootLoadEnabled(false);
      expect(off.lastScript, contains('rm -f'));
    });
  });

  group('switchToInject', () {
    test('throws a precondition when cfg80211 is not staged', () {
      expect(
        () => ModuleRepository(FakeRootRunner()).switchToInject(const []),
        throwsA(isA<ModulePrecondition>()),
      );
    });

    test('evicts the vendor stack and inserts our cfg80211', () async {
      final fake = FakeRootRunner((_) => const ShellResult(0, 'OK_INJECT'));
      await ModuleRepository(fake).switchToInject(const [
        ModuleInfo(name: 'cfg80211', loaded: false, isWifiClass: true),
        ModuleInfo(name: 'mac80211', loaded: false, isWifiClass: true),
      ]);
      expect(fake.lastScript, contains('rmmod cfg80211'));
      expect(fake.lastScript, contains("insmod '$kModulesDir/cfg80211.ko'"));
      expect(fake.lastScript, contains('OK_INJECT'));
    });
  });

  group('wifi switching (script shape)', () {
    test('switchToStock unloads the adapter and restores the vendor stack',
        () async {
      final fake = FakeRootRunner((_) => const ShellResult(0, 'OK_STOCK'));
      await ModuleRepository(fake).switchToStock(const [
        ModuleInfo(name: '88XXau', loaded: true, isWifiClass: true),
      ]);
      expect(fake.lastScript, contains("rmmod '88XXau'"));
      expect(fake.lastScript, contains('OK_STOCK'));
    });

    test('reconfigureManaged reloads the chipset and re-enables the iface',
        () async {
      final fake = FakeRootRunner((_) => const ShellResult(0, 'OK_RECONFIG:wlan0'));
      await ModuleRepository(fake).reconfigureManaged(
        chipsetDriver: '88XXau',
        iface: 'wlan0',
        reloadDriver: true,
      );
      expect(fake.lastScript, contains("insmod '$kModulesDir/88XXau.ko'"));
      expect(fake.lastScript, contains('OK_RECONFIG'));
    });
  });

  group('update delivery', () {
    test('installedModulesVersionCode parses the stamped code, 0 otherwise',
        () async {
      expect(
        await ModuleRepository(FakeRootRunner((_) => const ShellResult(0, '60072228')))
            .installedModulesVersionCode(),
        60072228,
      );
      expect(
        await ModuleRepository(FakeRootRunner((_) => const ShellResult(0, '')))
            .installedModulesVersionCode(),
        0,
      );
    });

    test('installModuleZip tries ksud then magisk, else NO_MODULE_MANAGER',
        () async {
      final fake = FakeRootRunner((_) => const ShellResult(0, ''));
      await ModuleRepository(fake).installModuleZip('/tmp/mods.zip');
      expect(fake.lastScript, contains('ksud module install'));
      expect(fake.lastScript, contains('magisk --install-module'));
      expect(fake.lastScript, contains('NO_MODULE_MANAGER'));
    });

    test('copyToDownloads reports success only on the OK marker', () async {
      expect(
        await ModuleRepository(FakeRootRunner((_) => const ShellResult(0, 'OK')))
            .copyToDownloads('/tmp/a.zip', 'a.zip'),
        isTrue,
      );
      expect(
        await ModuleRepository(FakeRootRunner((_) => const ShellResult(1, 'nope')))
            .copyToDownloads('/tmp/a.zip', 'a.zip'),
        isFalse,
      );
    });

    test('flashKernelZip targets the inactive slot only when asked', () async {
      final inactive = FakeRootRunner((_) => const ShellResult(0, 'AK3_EXIT:0'));
      await ModuleRepository(inactive)
          .flashKernelZip('/tmp/k.zip', inactiveSlot: true);
      expect(inactive.lastScript, contains('export slot_select=inactive'));

      final active = FakeRootRunner((_) => const ShellResult(0, 'AK3_EXIT:0'));
      await ModuleRepository(active)
          .flashKernelZip('/tmp/k.zip', inactiveSlot: false);
      expect(active.lastScript, isNot(contains('slot_select=inactive')));
    });

    test('slotInfo distinguishes A/B from single-slot devices', () async {
      expect(
        await ModuleRepository(FakeRootRunner((_) => const ShellResult(0, 'AB _a')))
            .slotInfo(),
        (true, '_a'),
      );
      expect(
        await ModuleRepository(FakeRootRunner((_) => const ShellResult(0, 'SINGLE ')))
            .slotInfo(),
        (false, ''),
      );
    });
  });

  group('device gate (isSupportedDevice)', () {
    test('parseDeviceIdentity reads SOC/BRAND/MARKET lines', () {
      final id = parseDeviceIdentity(
          'SOC:SM8850\nBRAND:Xiaomi\nMARKET:Xiaomi 17 Pro Max');
      expect(id.socModel, 'SM8850');
      expect(id.brand, 'Xiaomi');
      expect(id.marketName, 'Xiaomi 17 Pro Max');
    });

    test('accepts every Xiaomi 17 model by market name', () {
      for (final m in [
        'Xiaomi 17',
        'Xiaomi 17 Pro',
        'Xiaomi 17 Pro Max',
        'Xiaomi 17 Ultra',
      ]) {
        expect(
          isSupportedDevice(
              DeviceIdentity(socModel: 'SM8850', brand: 'Xiaomi', marketName: m)),
          isTrue,
          reason: m,
        );
      }
    });

    test('accepts the Xiaomi-branded sm8850 combo when market name is blank', () {
      expect(
        isSupportedDevice(const DeviceIdentity(
            socModel: 'SM8850', brand: 'Xiaomi', marketName: '')),
        isTrue,
      );
    });

    test('rejects a different SoC even on a Xiaomi phone', () {
      expect(
        isSupportedDevice(const DeviceIdentity(
            socModel: 'SM8750', brand: 'Xiaomi', marketName: '')),
        isFalse,
      );
    });

    test('rejects another vendor\'s sm8850 phone (no Xiaomi 17 market name)', () {
      expect(
        isSupportedDevice(const DeviceIdentity(
            socModel: 'SM8850', brand: 'Samsung', marketName: 'Galaxy S30')),
        isFalse,
      );
    });

    test('deviceIdentity is one round-trip reading the gate props', () async {
      final fake = FakeRootRunner(
          (_) => const ShellResult(0, 'SOC:SM8850\nBRAND:Xiaomi\nMARKET:Xiaomi 17'));
      final id = await ModuleRepository(fake).deviceIdentity();
      expect(fake.scripts, hasLength(1));
      expect(fake.lastScript, contains('ro.soc.model'));
      expect(isSupportedDevice(id), isTrue);
    });
  });
}
