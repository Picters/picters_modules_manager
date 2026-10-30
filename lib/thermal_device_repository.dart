import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'device_controls.dart';
import 'native_bridge.dart';
import 'root_shell.dart';
import 'thermal_policy_pack.dart';

/// Android transport for the captured firmware ABI. Hardware behavior still
/// requires device validation; source checks do not establish it.
class XiaomiThermalRepository implements DeviceControlsRepository {
  XiaomiThermalRepository({
    RootRunner? runner,
    Future<String> Function(Uint8List)? decode,
    Future<Uint8List> Function(String)? encode,
  }) : _runner = runner ?? const DefaultRootRunner(),
       _decode = decode ?? NativeBridge.decodeThermalPolicy,
       _encode = encode ?? NativeBridge.encodeThermalOverride;

  final RootRunner _runner;
  final Future<String> Function(Uint8List) _decode;
  final Future<Uint8List> Function(String) _encode;
  static const helper = '/data/adb/modules/picters-modules-pack/thermalctl.sh';
  static const stateDir = '/data/adb/picters_modules_manager/thermal';
  static const chargingHelper =
      '/data/adb/modules/picters-modules-pack/chargingctl.sh';
  bool _stockPersist = false;
  int _lastTemperature = 45;
  String? _vendor;

  @override
  bool get preview => false;
  @override
  DeviceControlsState get initialState => DeviceControlsState.unverified;

  Future<String> _run(String script) async {
    // The persistent su session must not inherit set -e, variables or traps.
    final result = await _runner.run(
      '(\nset -eu\n$script\n)',
      timeout: const Duration(seconds: 45),
    );
    if (!result.ok) throw StateError(result.errorSummary);
    return result.stdout;
  }

  @override
  Future<DeviceControlsState> scan() async {
    try {
      final output = await _run('''
[ "\$(getprop ro.product.device)" = pudding ]
[ -f '$helper' ]
[ ! -e /data/adb/modules/picters-modules-pack/disable ]
[ ! -e /data/adb/modules/picters-modules-pack/remove ]
[ "\$(uname -r)" = "\$(cat /data/adb/modules/picters-modules-pack/expected-kernel)" ]
[ "\$(sh '$helper' api)" = PMM_THERMAL_FILES_V1 ]
PMM_VENDOR=\$(getprop ro.vendor.build.fingerprint)
[ -n "\$PMM_VENDOR" ]
PMM_LOADER=\$(sha256sum /vendor/bin/mi_thermald)
PMM_LOADER=\${PMM_LOADER%% *}
[ "\$PMM_LOADER" = df25b03dfb7081c6b85e130a457f48b049c0f2056979ee407208d5fdf86b057e ]
printf 'vendor=%s\\n' "\$PMM_VENDOR"
sh '$helper' status
if PMM_CHARGING=\$(sh '$chargingHelper' status 2>/dev/null); then
  printf 'charging_available=1\\n%s\\n' "\$PMM_CHARGING"
else printf 'charging_available=0\\n'; fi
''');
      final fields = <String, String>{};
      for (final line in output.split('\n')) {
        final split = line.indexOf('=');
        if (split > 0) {
          fields[line.substring(0, split)] = line.substring(split + 1);
        }
      }
      final vendor = fields['vendor'];
      final target = fields['target'];
      if (vendor == null ||
          vendor.isEmpty ||
          !{'0', '1'}.contains(fields['persist'])) {
        return initialState;
      }
      final temperature = int.tryParse(target ?? '');
      if (target != 'stock' &&
          target != 'off' &&
          (temperature == null || temperature < 25 || temperature > 65)) {
        return initialState;
      }
      _vendor = vendor;
      if (temperature != null) _lastTemperature = temperature;
      return DeviceControlsState(
        support: DeviceControlSupport.available,
        thermalAvailable: true,
        chargingAvailable: fields['charging_available'] == '1',
        settings: DeviceControlSettings(
          thermalPreset: target == 'stock'
              ? ThermalPreset.stock
              : ThermalPreset.custom,
          customTemp: _lastTemperature.toDouble(),
          thermalLimitDisabled: target == 'off',
          persistOnBoot: target == 'stock'
              ? _stockPersist
              : fields['persist'] == '1',
          chargingEnabled: fields['charging'] == '1',
          inputLimitDisabled: fields['power_target'] == 'off',
          inputLimit: double.tryParse(fields['power_target'] ?? '') ?? 100,
        ),
      );
    } catch (_) {
      return initialState;
    }
  }

  @override
  Future<DeviceControlsState> apply(DeviceControlSettings settings) async {
    if (!settings.customTemp.isFinite ||
        settings.customTemp != settings.customTemp.roundToDouble() ||
        settings.customTemp < 25 ||
        settings.customTemp > 65) {
      throw const FormatException(
        'Choose a whole-degree thermal target from 25 to 65 °C.',
      );
    }
    final current = await scan();
    if (!current.thermalAvailable) {
      throw UnsupportedError(DeviceControlsController.verificationPending);
    }
    if (settings.bypassRequested || settings.chargeLimit != 100) {
      throw UnsupportedError(
        'Battery bypass and charge ceilings are unsupported.',
      );
    }
    if (settings.chargingEnabled &&
        (!current.chargingAvailable ||
            settings.thermalPreset != ThermalPreset.custom ||
            !settings.thermalLimitDisabled)) {
      throw UnsupportedError(DeviceControlsController.powerRequiresThermalOff);
    }
    if (!settings.inputLimit.isFinite ||
        settings.inputLimit != settings.inputLimit.roundToDouble() ||
        settings.inputLimit < 1 ||
        settings.inputLimit > 120) {
      throw const FormatException(
        'Choose a whole-watt target from 1 to 120 W.',
      );
    }
    if (current.settings.chargingEnabled && !settings.chargingEnabled) {
      await _run("sh '$chargingHelper' restore");
    }
    if (!{
      ThermalPreset.stock,
      ThermalPreset.custom,
    }.contains(settings.thermalPreset)) {
      throw UnsupportedError('Choose Stock or a custom thermal target.');
    }
    if (settings.thermalPreset == ThermalPreset.stock) {
      await _run("sh '$helper' restore");
    } else if (current.settings.thermalPreset == settings.thermalPreset &&
        current.settings.customTemp == settings.customTemp &&
        current.settings.thermalLimitDisabled ==
            settings.thermalLimitDisabled) {
      await _run("sh '$helper' persist ${settings.persistOnBoot ? 1 : 0}");
    } else {
      await _install(settings);
    }
    _stockPersist = settings.persistOnBoot;
    if (settings.chargingEnabled) {
      final power = settings.inputLimitDisabled
          ? 'off'
          : settings.inputLimit.toInt().toString();
      await _run(
        "sh '$chargingHelper' apply $power ${settings.persistOnBoot ? 1 : 0}",
      );
    }
    final next = await scan();
    if (!next.thermalAvailable ||
        next.settings.thermalPreset != settings.thermalPreset ||
        next.settings.persistOnBoot != settings.persistOnBoot ||
        next.settings.chargingEnabled != settings.chargingEnabled ||
        (settings.chargingEnabled &&
            (next.settings.inputLimitDisabled != settings.inputLimitDisabled ||
                (!settings.inputLimitDisabled &&
                    next.settings.inputLimit != settings.inputLimit))) ||
        (settings.thermalPreset == ThermalPreset.custom &&
            (next.settings.thermalLimitDisabled !=
                    settings.thermalLimitDisabled ||
                (!settings.thermalLimitDisabled &&
                    next.settings.customTemp != settings.customTemp)))) {
      throw StateError('Thermal state readback did not match the request.');
    }
    return next;
  }

  Future<void> _install(DeviceControlSettings settings) async {
    final raw = await _run('''
for PMM_FILE in /odm/etc/thermal-*.conf; do
  [ -f "\$PMM_FILE" ] && [ ! -L "\$PMM_FILE" ] || continue
  PMM_SIZE=\$(stat -c %s "\$PMM_FILE")
  [ "\$PMM_SIZE" -gt 0 ] && [ "\$PMM_SIZE" -le 2097152 ]
  printf '%s|' "\${PMM_FILE##*/}"
  base64 "\$PMM_FILE" | tr -d '\\n'
  printf '\\n'
done
''');
    final stock = <String, String>{};
    for (final line in raw.split('\n').where((line) => line.isNotEmpty)) {
      final split = line.indexOf('|');
      if (split <= 0) {
        throw const FormatException('Invalid stock policy response.');
      }
      final name = line.substring(0, split);
      if (!RegExp(r'^thermal-[a-z0-9-]+\.conf$').hasMatch(name) ||
          stock.containsKey(name)) {
        throw const FormatException('Invalid stock policy filename.');
      }
      if (stock.length >= 256) {
        throw const FormatException('Too many stock policies.');
      }
      stock[name] = await _decode(base64Decode(line.substring(split + 1)));
    }
    final pack = ThermalPolicyPack.prepare(
      vendorFingerprint: _vendor!,
      stockPolicies: stock,
      temperatureC: settings.customTemp.toInt(),
      disabled: settings.thermalLimitDisabled,
    );
    final encoded = await pack.encodeVerified(encode: _encode, decode: _decode);
    final stage = (await _run(
      "mkdir -p '$stateDir'; mktemp -d '$stateDir/.stage.XXXXXX'",
    )).trim();
    if (!RegExp(
      '^${RegExp.escape(stateDir)}/\\.stage\\.[A-Za-z0-9]+\$',
    ).hasMatch(stage)) {
      throw const FormatException('Invalid thermal staging directory.');
    }
    try {
      await _run("mkdir '$stage/files'");
      for (final entry in encoded.entries) {
        final path = '$stage/files/${entry.key}';
        await _write(path, entry.value);
        final readback = await _run("base64 '$path' | tr -d '\\n'");
        if (!listEquals(base64Decode(readback), entry.value)) {
          throw StateError('Thermal staging readback failed: ${entry.key}');
        }
      }
      await _write('$stage/vendor-fingerprint', utf8.encode(_vendor!));
      await _write(
        '$stage/target',
        utf8.encode(
          settings.thermalLimitDisabled
              ? 'off'
              : '${settings.customTemp.toInt()}',
        ),
      );
      await _write(
        '$stage/persist',
        utf8.encode(settings.persistOnBoot ? '1' : '0'),
      );
      await _run('''
(cd '$stage/files' && sha256sum thermal-*.conf) > '$stage/manifest.sha256'
rm -rf '$stateDir/stage'
mv '$stage' '$stateDir/stage'
sh '$helper' apply
''');
    } finally {
      try {
        await _run("rm -rf '$stage'");
      } catch (_) {
        // A lost root session must not hide the original operation failure.
      }
    }
  }

  Future<void> _write(String path, List<int> bytes) async {
    await _run(": > '$path'");
    final encoded = base64Encode(bytes);
    // Keep each Binder request below its transaction-size limit.
    for (var offset = 0; offset < encoded.length; offset += 32768) {
      final chunk = encoded.substring(
        offset,
        (offset + 32768).clamp(0, encoded.length),
      );
      await _run("printf '%s' '$chunk' | base64 -d >> '$path'");
    }
  }
}
