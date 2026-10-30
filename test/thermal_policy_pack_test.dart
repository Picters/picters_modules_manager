import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/thermal_policy_pack.dart';

const _stock = '''[CPU]
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

void main() {
  ThermalPolicyPack prepare({int temperature = 45, bool off = false}) =>
      ThermalPolicyPack.prepare(
        vendorFingerprint: 'Xiaomi/pudding:16/test',
        stockPolicies: {
          'thermal-normal.conf': _stock,
          'thermal-gl-mgame.conf': _stock,
          'thermal-map-gl.conf': '[0:thermal-gl-normal.conf]\n',
        },
        temperatureC: temperature,
        disabled: off,
      );

  test('all scenarios cover the range and preserve unrelated rules', () {
    for (var temperature = 25; temperature <= 65; temperature++) {
      final pack = prepare(temperature: temperature);
      expect(pack.policies.length, 2);
      for (final draft in pack.policies.values) {
        expect(draft.text, contains('trig\t${temperature * 1000}'));
        expect(
          draft.text,
          contains(_stock.substring(_stock.indexOf('[CHARGE]'))),
        );
      }
    }
    for (final draft in prepare(off: true).policies.values) {
      expect(draft.text, isNot(contains('[CPU]')));
      expect(draft.text, contains('[CHARGE]'));
    }
  });

  test('bad baseline or traversal rejects the entire pack', () {
    for (final policies in <Map<String, String>>[
      {},
      {'../thermal-normal.conf': _stock},
      {'thermal-normal.conf': ''},
      {
        'thermal-normal.conf': _stock,
        'thermal-video.conf': '[bad]\ndevice cpu0\ndevice gpu\n',
      },
    ]) {
      expect(
        () => ThermalPolicyPack.prepare(
          vendorFingerprint: 'Xiaomi/pudding:16/test',
          stockPolicies: policies,
          temperatureC: 45,
        ),
        throwsFormatException,
      );
    }
  });

  test('a codec mismatch never returns a partial deployment set', () async {
    var decoded = 0;
    final pack = prepare();
    await expectLater(
      pack.encodeVerified(
        encode: (text) async => Uint8List.fromList(utf8.encode(text)),
        decode: (bytes) async =>
            ++decoded == 2 ? 'corrupt' : utf8.decode(bytes),
      ),
      throwsFormatException,
    );
    expect(decoded, 2);
    final encoded = await pack.encodeVerified(
      encode: (text) async => Uint8List.fromList(utf8.encode(text)),
      decode: (bytes) async => utf8.decode(bytes),
    );
    expect(encoded.keys, pack.policies.keys);
  });
}
