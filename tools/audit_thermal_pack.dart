import 'dart:io';
import 'package:picters_modules_manager/thermal_policy_pack.dart';

// Read-only validation of a decoded capture. No files are generated or deployed.
void main(List<String> args) {
  if (args.length != 1) throw ArgumentError('Pass the decoded ODM directory.');
  final policies = <String, String>{};
  for (final file in Directory(args.single).listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (name.startsWith('thermal-') && name.endsWith('.conf')) {
      policies[name] = file.readAsStringSync();
    }
  }
  var scenarios = 0;
  for (var target = 25; target <= 66; target++) {
    final pack = ThermalPolicyPack.prepare(
      vendorFingerprint: 'captured-pudding-vendor',
      stockPolicies: policies,
      temperatureC: target == 66 ? 45 : target,
      disabled: target == 66,
    );
    if (scenarios != 0 && scenarios != pack.policies.length) {
      throw StateError('Scenario set changed across temperatures.');
    }
    scenarios = pack.policies.length;
  }
  stdout.writeln(
    'Validated $scenarios scenarios at every 25–65 °C target and Off.',
  );
}
