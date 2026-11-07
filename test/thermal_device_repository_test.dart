import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/device_controls.dart';
import 'package:picters_modules_manager/root_shell.dart';
import 'package:picters_modules_manager/thermal_device_repository.dart';

const stock = '''[CPU]
algo_type monitor
sensor VIRTUAL-SENSOR-FORMULA
device cpu0
trig 45000 47000
clr 43000 45000
target 3000000 2000000
[CHARGE]
algo_type monitor
sensor battery
device battery
trig 48000
clr 46000
target 1000
''';

class _Phone implements RootRunner {
  bool verified = true;
  bool corruptReadback = false;
  bool failStockRead = false;
  bool includeRegionMap = false;
  bool failActivation = false;
  String filename = 'thermal-normal.conf';
  String target = 'stock';
  String persist = '0';
  final files = <String, List<int>>{};
  final scripts = <String>[];
  int installs = 0;
  static const stage = '${XiaomiThermalRepository.stateDir}/.stage.ABC123';

  @override
  Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    scripts.add(script);
    expect(script.startsWith('(\nset -eu\n'), isTrue);
    if (script.contains('getprop ro.product.device')) {
      expect(script, contains('df25b03dfb7081c6'));
      expect(script, contains('expected-kernel'));
      expect(script, contains('picters-modules-pack/disable'));
      expect(script, contains('picters-modules-pack/remove'));
      return verified
          ? ShellResult(
              0,
              'vendor=fixture-vendor\ntarget=$target\npersist=$persist\n',
            )
          : const ShellResult(1, 'Device verification pending');
    }
    if (script.contains('for PMM_FILE in')) {
      if (failStockRead) {
        return const ShellResult(1, 'root output transport failed');
      }
      return ShellResult(
        0,
        '$filename|${base64Encode(utf8.encode(stock))}'
        '${includeRegionMap ? "\nthermal-region-map.conf|${base64Encode(utf8.encode('2.11.0:thermal-map-gl.conf\n2.29.0:thermal-map-ind.conf'))}" : ""}',
      );
    }
    if (script.contains('mktemp -d')) return const ShellResult(0, stage);
    final create = RegExp(r": > '([^']+)'").firstMatch(script);
    if (create != null) files[create[1]!] = [];
    final append = RegExp(
      r"printf '%s' '([^']*)' \| base64 -d >> '([^']+)'",
    ).firstMatch(script);
    if (append != null) files[append[2]!]!.addAll(base64Decode(append[1]!));
    final read = RegExp(r"base64 '([^']+)'").firstMatch(script);
    if (read != null) {
      return ShellResult(
        0,
        base64Encode(corruptReadback ? [0] : files[read[1]]!),
      );
    }
    if (script.contains("sh '${XiaomiThermalRepository.helper}' apply")) {
      installs++;
      if (failActivation) {
        return const ShellResult(1, 'Thermal service restart failed');
      }
      target = utf8.decode(files['$stage/target']!);
      persist = utf8.decode(files['$stage/persist']!);
    } else if (script.contains(
      "sh '${XiaomiThermalRepository.helper}' restore",
    )) {
      target = 'stock';
      persist = '0';
    } else if (script.contains(
      "sh '${XiaomiThermalRepository.helper}' persist",
    )) {
      persist = RegExp(r'persist ([01])').firstMatch(script)![1]!;
    }
    return const ShellResult(0, '');
  }
}

DeviceControlsController _controls(_Phone phone) => DeviceControlsController(
  repository: XiaomiThermalRepository(
    runner: phone,
    decode: (bytes) async {
      final text = utf8.decode(bytes);
      if (text.startsWith('2.11.0:')) {
        throw const FormatException(
          'Routing metadata is not an encrypted policy',
        );
      }
      return text;
    },
    encode: (text) async => Uint8List.fromList(utf8.encode(text)),
  ),
);

void main() {
  test(
    'plaintext region routing metadata is neither decoded nor installed',
    () async {
      final phone = _Phone()..includeRegionMap = true;
      final controller = _controls(phone);
      addTearDown(controller.dispose);
      await controller.init();
      expect(await controller.setCustomTemp(45), isTrue);
      expect(phone.installs, 1);
      expect(controller.busy, isFalse);
      expect(
        phone.files.keys.any(
          (path) => path.endsWith('thermal-region-map.conf'),
        ),
        isFalse,
      );
      expect(
        phone.scripts.firstWhere(
          (script) => script.contains('for PMM_FILE in'),
        ),
        contains('!= thermal-region-map.conf'),
      );
    },
  );
  test(
    'stock read transport failure releases controls without installing a profile',
    () async {
      final phone = _Phone()..failStockRead = true;
      final controller = _controls(phone);
      addTearDown(controller.dispose);
      await controller.init();
      expect(await controller.setCustomTemp(45), isFalse);
      expect(controller.busy, isFalse);
      expect(controller.thermalPreset, ThermalPreset.stock);
      expect(phone.installs, 0);
      expect(phone.files, isEmpty);
      expect(controller.lastError, contains('root output transport failed'));
      phone.failStockRead = false;
      expect(await controller.setCustomTemp(45), isTrue);
      expect(controller.busy, isFalse);
      expect(phone.installs, 1);
    },
  );
  test('no device verification means no staging or native writes', () async {
    final phone = _Phone()..verified = false;
    final controller = _controls(phone);
    addTearDown(controller.dispose);
    await controller.init();
    expect(controller.thermalSupported, isFalse);
    expect(await controller.setCustomTemp(55), isFalse);
    expect(phone.installs, 0);
    expect(phone.files, isEmpty);
  });

  test(
    'profile transport verifies files, supports Off, persistence and restore',
    () async {
      final phone = _Phone();
      final controller = _controls(phone);
      addTearDown(controller.dispose);
      await controller.init();
      expect(controller.thermalSupported, isTrue);
      expect(await controller.setCustomTemp(55), isTrue);
      expect(controller.customTemp, 55);
      final text = utf8.decode(
        phone.files['${_Phone.stage}/files/thermal-normal.conf']!,
      );
      expect(text, contains('trig\t55000\t57000'));
      expect(text, contains(stock.substring(stock.indexOf('[CHARGE]'))));
      expect(await controller.setBootPersistence(true), isTrue);
      expect(phone.persist, '1');
      expect(await controller.setThermalLimitDisabled(true), isTrue);
      expect(controller.thermalLimitDisabled, isTrue);
      expect(await controller.restoreThermalStock(), isTrue);
      expect(controller.thermalPreset, ThermalPreset.stock);
      expect(controller.state.settings.persistOnBoot, isTrue);
    },
  );

  test(
    'corrupt staging and failed restart never commit a controller selection',
    () async {
      for (final corrupt in [true, false]) {
        final phone = _Phone()
          ..corruptReadback = corrupt
          ..failActivation = !corrupt;
        final controller = _controls(phone);
        await controller.init();
        expect(await controller.setCustomTemp(65), isFalse);
        expect(controller.thermalPreset, ThermalPreset.stock);
        expect(phone.installs, corrupt ? 0 : 1);
        expect(controller.lastError, isNotNull);
        controller.dispose();
      }
    },
  );

  test(
    'untrusted stock filenames are rejected before root file creation',
    () async {
      final phone = _Phone()..filename = '../thermal-normal.conf';
      final controller = _controls(phone);
      addTearDown(controller.dispose);
      await controller.init();
      expect(await controller.setCustomTemp(55), isFalse);
      expect(phone.files, isEmpty);
      expect(phone.installs, 0);
    },
  );
}
