import 'dart:convert';
import 'dart:io';

import 'package:picters_modules_manager/thermal_profile.dart';

void main(List<String> args) {
  if (args.length != 1) {
    throw ArgumentError('Pass the decoded stock directory.');
  }
  final files =
      Directory(args.single)
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                f.path.endsWith('.conf') &&
                !f.path.split('/').last.contains('map'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final stock = file.readAsStringSync();
    for (var temperature = 25; temperature <= 66; temperature++) {
      final off = temperature == 66;
      final draft = ThermalProfileBuilder.build(
        stock,
        temperatureC: off ? 45 : temperature,
        disabled: off,
      );
      stdout.writeln(
        jsonEncode({
          'file': file.path.split('/').last,
          'temperature': off ? 45 : temperature,
          'off': off,
          'text': draft.text,
          'sections': draft.changedSections,
        }),
      );
    }
  }
}
