import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/module_dependencies.dart';

void main() {
  // A representative slice of the shipped .ko set — enough for these cases.
  final available = <String>{
    'cfg80211', 'mac80211',
    'rtlwifi', 'rtl_usb', 'rtl8192cu', 'rtl8192c-common', 'rtl8xxxu',
    'rt2x00lib', 'rt2x00usb', 'rt2800lib', 'rt2800usb',
    'ath', 'ath9k_hw', 'ath9k_common', 'ath9k_htc',
    '88XXau', 'usbserial', 'cp210x', 'can', 'can-raw', 'i2c-mux', 'rtl2832',
    'ntfs3',
  };

  group('planModuleLoad', () {
    test('rtl8192cu pulls rtlwifi / rtl8192c-common / rtl_usb, in order', () {
      final plan = planModuleLoad(
        target: 'rtl8192cu',
        available: available,
        loaded: const {},
        injectActive: true,
      );
      expect(plan.needsInjectMode, isFalse);
      // rtlwifi is the base of the family and must be first; the two leaves may
      // follow. Order is deterministic from the dep lists.
      expect(plan.toLoad, ['rtlwifi', 'rtl8192c-common', 'rtl_usb']);
    });

    test('already-loaded dependencies are skipped', () {
      final plan = planModuleLoad(
        target: 'rtl8192cu',
        available: available,
        loaded: const {'rtlwifi'},
        injectActive: true,
      );
      expect(plan.toLoad, ['rtl8192c-common', 'rtl_usb']);
    });

    test('rt2800usb resolves the rt2x00 chain', () {
      final plan = planModuleLoad(
        target: 'rt2800usb',
        available: available,
        loaded: const {},
        injectActive: true,
      );
      expect(plan.toLoad, ['rt2x00lib', 'rt2x00usb', 'rt2800lib']);
    });

    test('ath9k_htc resolves the ath chain', () {
      final plan = planModuleLoad(
        target: 'ath9k_htc',
        available: available,
        loaded: const {},
        injectActive: true,
      );
      expect(plan.toLoad, ['ath', 'ath9k_hw', 'ath9k_common']);
    });

    test('a self-contained Wi-Fi driver needs only the injection core', () {
      final on = planModuleLoad(
        target: '88XXau',
        available: available,
        loaded: const {},
        injectActive: true,
      );
      expect(on.toLoad, isEmpty);
      expect(on.needsInjectMode, isFalse);
      expect(on.ready, isTrue);

      final off = planModuleLoad(
        target: '88XXau',
        available: available,
        loaded: const {},
        injectActive: false,
      );
      expect(off.needsInjectMode, isTrue);
    });

    test('non-Wi-Fi chains resolve without needing Inject mode', () {
      expect(
        planModuleLoad(
          target: 'cp210x',
          available: available,
          loaded: const {},
          injectActive: false,
        ).toLoad,
        ['usbserial'],
      );
      expect(
        planModuleLoad(
          target: 'can-raw',
          available: available,
          loaded: const {},
          injectActive: false,
        ).toLoad,
        ['can'],
      );
      expect(
        planModuleLoad(
          target: 'rtl2832',
          available: available,
          loaded: const {},
          injectActive: false,
        ).toLoad,
        ['i2c-mux'],
      );
    });

    test('a module with no shipped deps loads on its own', () {
      final plan = planModuleLoad(
        target: 'ntfs3',
        available: available,
        loaded: const {},
        injectActive: false,
      );
      expect(plan.ready, isTrue);
    });
  });

  group('loadedDependents', () {
    test('lists rtlwifi users, most-dependent first', () {
      final deps = loadedDependents(
        target: 'rtlwifi',
        available: available,
        loaded: const {'rtlwifi', 'rtl_usb', 'rtl8192c-common', 'rtl8192cu'},
      );
      expect(deps.toSet(), {'rtl8192cu', 'rtl_usb', 'rtl8192c-common'});
      // rtl8192cu depends on rtl_usb + rtl8192c-common, so it must be removed
      // before either of them.
      expect(deps.first, 'rtl8192cu');
      expect(deps.indexOf('rtl8192cu'), lessThan(deps.indexOf('rtl_usb')));
    });

    test('a leaf driver has no dependents', () {
      final deps = loadedDependents(
        target: 'rtl8192cu',
        available: available,
        loaded: const {'rtlwifi', 'rtl_usb', 'rtl8192cu'},
      );
      expect(deps, isEmpty);
    });
  });
}
