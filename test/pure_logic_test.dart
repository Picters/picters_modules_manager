import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/app_controller.dart';
import 'package:picters_modules_manager/module_categories.dart';
import 'package:picters_modules_manager/module_info.dart';
import 'package:picters_modules_manager/module_repository.dart';
import 'package:picters_modules_manager/root_shell.dart';
import 'package:picters_modules_manager/update_checker.dart';
import 'package:picters_modules_manager/usb_devices.dart';

void main() {
  group('isNewerVersion', () {
    test('numeric ordering, including multi-digit segments', () {
      expect(isNewerVersion('1.10.0', '1.9.9'), isTrue);
      expect(isNewerVersion('1.0.1', '1.0.0'), isTrue);
      expect(isNewerVersion('2.0', '1.9'), isTrue);
      expect(isNewerVersion('1.0.0', '1.0.1'), isFalse);
    });

    test('equal versions are not newer', () {
      expect(isNewerVersion('1.2.3', '1.2.3'), isFalse);
    });

    test('trailing zeros compare equal across lengths', () {
      expect(isNewerVersion('1.2.0', '1.2'), isFalse);
      expect(isNewerVersion('1.2.1', '1.2'), isTrue);
    });

    test('non-numeric parts fall back to string inequality', () {
      expect(isNewerVersion('1.2.0-beta', '1.2.0'), isTrue);
      expect(isNewerVersion('1.2.0', '1.2.0'), isFalse);
    });
  });

  group('parseUsbLines', () {
    test('recognises a known adapter and maps it to its driver', () {
      final r = parseUsbLines(['${usbMarker}0bda|8812|Realtek|RTL8812AU']);
      expect(r, hasLength(1));
      expect(r.first.recognized, isTrue);
      expect(r.first.match!.driver, '88XXau');
      expect(r.first.device.idPair, '0bda:8812');
    });

    test('keeps an unknown device but leaves it unmatched', () {
      final r = parseUsbLines(['${usbMarker}1234|abcd|Acme|Widget']);
      expect(r, hasLength(1));
      expect(r.first.recognized, isFalse);
      expect(r.first.device.displayName, 'Widget');
    });

    test('skips noise lines and lines missing a product id', () {
      final r = parseUsbLines(['just noise', '${usbMarker}0bda']);
      expect(r, isEmpty);
    });

    test('is case-insensitive on VID:PID', () {
      final r = parseUsbLines(['${usbMarker}0BDA|8812|x|y']);
      expect(r.first.match!.driver, '88XXau');
    });
  });

  group('parseIfaceLines', () {
    test('parses name/driver/up/monitor from a scan line (IFF_UP flag)', () {
      // 0x1003 has IFF_UP (bit 0); ARPHRD 803 = monitor.
      final r = parseIfaceLines(['${ifaceMarker}wlan1|88XXau|0x1003|803']);
      expect(r, hasLength(1));
      expect(r.first.name, 'wlan1');
      expect(r.first.driver, '88XXau');
      expect(r.first.up, isTrue);
      expect(r.first.monitor, isTrue); // ARPHRD 803 = radiotap/monitor
    });

    test('type 1 (ether) is managed; IFF_UP clear reads as down', () {
      // 0x1002 = IFF_BROADCAST|... but NOT IFF_UP (bit 0) → admin-down.
      final r = parseIfaceLines(['${ifaceMarker}wlan0|qca_cld3|0x1002|1']);
      expect(r.first.monitor, isFalse);
      expect(r.first.up, isFalse);
    });

    test('a monitor VIF admin-up reads up even with no carrier', () {
      // Real monitor case: IFF_UP set (0x1003) though operstate is "unknown".
      final r = parseIfaceLines(['${ifaceMarker}wlan0|88x2bu|0x1003|803']);
      expect(r.first.up, isTrue);
      expect(r.first.monitor, isTrue);
    });

    test('skips noise and lines with an empty interface name', () {
      final r = parseIfaceLines(['noise', '$ifaceMarker|88XXau|0x1003|1']);
      expect(r, isEmpty);
    });
  });

  group('ifaceFlagUp', () {
    test('IFF_UP (bit 0) decides admin up/down', () {
      expect(ifaceFlagUp('0x1003'), isTrue); // ...0011 → IFF_UP set
      expect(ifaceFlagUp('0x1002'), isFalse); // ...0010 → IFF_UP clear
      expect(ifaceFlagUp('0x1'), isTrue);
      expect(ifaceFlagUp('0x0'), isFalse);
    });

    test('tolerates whitespace, missing 0x, and garbage', () {
      expect(ifaceFlagUp(' 1003 '), isTrue); // bare hex
      expect(ifaceFlagUp(''), isFalse);
      expect(ifaceFlagUp('xyz'), isFalse);
    });
  });

  group('module categories', () {
    test('categoryOf maps known modules and defaults to other', () {
      expect(categoryOf('btusb'), ModuleCategory.bluetooth);
      expect(categoryOf('can-raw'), ModuleCategory.can);
      expect(categoryOf('cp210x'), ModuleCategory.usbSerial);
      expect(categoryOf('ntfs3'), ModuleCategory.filesystem);
      expect(categoryOf('totally-unknown'), ModuleCategory.other);
    });

    test('moduleDescription is present only for documented modules', () {
      expect(moduleDescription('cfg80211'), isNotNull);
      expect(moduleDescription('some-random-ko'), isNull);
    });
  });

  group('ShellResult.errorSummary', () {
    test('skips java/binder noise and returns the meaningful line', () {
      const out = 'Failure [INSTALL_FAILED_INVALID_APK]\n'
          '\tat com.android.server.pm.Installer.x(Installer.java:1)\n'
          'android.os.Binder.execTransact';
      expect(
        const ShellResult(1, out).errorSummary,
        'Failure [INSTALL_FAILED_INVALID_APK]',
      );
    });

    test('empty output falls back to the exit code', () {
      expect(const ShellResult(5, '').errorSummary, 'exit code 5');
    });
  });

  group('ModuleInfo / SystemState', () {
    test('krName normalises dashes to underscores', () {
      expect(
        const ModuleInfo(name: 'rtl8192c-common', loaded: false, isWifiClass: true)
            .krName,
        'rtl8192c_common',
      );
      expect(
        const ModuleInfo(name: 'rtl_usb', loaded: false, isWifiClass: true).krName,
        'rtl_usb',
      );
    });

    test('fingerprint changes when a load state flips', () {
      SystemState withLoaded(bool loaded) => SystemState(
            modules: [ModuleInfo(name: 'x', loaded: loaded, isWifiClass: false)],
            adapters: const [],
            interfaces: const [],
            wifiMode: WifiMode.off,
            cfgLoaded: false,
            macLoaded: false,
            vendorWifiLoaded: false,
            modulesDirExists: true,
          );
      expect(withLoaded(false).fingerprint == withLoaded(true).fingerprint,
          isFalse);
    });
  });

  group('nextPollInterval', () {
    test('snaps back to fast the instant something changes', () {
      expect(nextPollInterval(const Duration(seconds: 5), changed: true),
          const Duration(seconds: 1));
    });

    test('eases out one second at a time, capped at slow', () {
      var d = const Duration(seconds: 1);
      d = nextPollInterval(d, changed: false);
      expect(d, const Duration(seconds: 2));
      d = nextPollInterval(d, changed: false);
      expect(d, const Duration(seconds: 3));
      for (var i = 0; i < 10; i++) {
        d = nextPollInterval(d, changed: false);
      }
      expect(d, const Duration(seconds: 5));
    });
  });

  group('isSafeAssetName', () {
    test('accepts the real date-stamped release asset names', () {
      expect(isSafeAssetName('Picters-OOT-Modules-20260719-2228.zip'), isTrue);
      expect(isSafeAssetName('Picters-Kernel-peach-20260719-2228.zip'), isTrue);
      expect(isSafeAssetName('app-release.apk'), isTrue);
      expect(isSafeAssetName('build_1.1.5+5.zip'), isTrue);
    });

    test('rejects shell-injection and path-traversal attempts', () {
      expect(isSafeAssetName("k';reboot;'.zip"), isFalse); // quote break-out
      expect(isSafeAssetName(r'k$(reboot).zip'), isFalse); // command sub
      expect(isSafeAssetName('k`reboot`.zip'), isFalse); // backtick sub
      expect(isSafeAssetName('../../evil.zip'), isFalse); // slash / traversal
      expect(isSafeAssetName('a b.zip'), isFalse); // whitespace
      expect(isSafeAssetName(''), isFalse); // empty
    });
  });

  group('hasApkMagic', () {
    test('accepts the ZIP/APK local-file-header magic', () {
      expect(hasApkMagic([0x50, 0x4B, 0x03, 0x04, 0x00]), isTrue);
    });

    test('rejects other content and short buffers', () {
      expect(hasApkMagic([0x3C, 0x21, 0x44, 0x4F]), isFalse); // "<!DO" (HTML)
      expect(hasApkMagic([0x50, 0x4B]), isFalse);
      expect(hasApkMagic(const []), isFalse);
    });
  });
}
