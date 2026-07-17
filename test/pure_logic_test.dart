import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/app_controller.dart';
import 'package:picters_modules_manager/module_categories.dart';
import 'package:picters_modules_manager/module_info.dart';
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
