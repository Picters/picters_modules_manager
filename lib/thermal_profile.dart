/// Pure thermal-policy editing. No file writes, root calls or service changes.
class ThermalProfileDraft {
  const ThermalProfileDraft(this.text, this.changedSections);
  final String text;
  final List<String> changedSections;
}

class ThermalProfileBuilder {
  static final _section = RegExp(
    r'(?=^\[[^\]\r\n]+\][ \t]*\r?$)',
    multiLine: true,
  );
  static final _hotplug = RegExp(r'^hotplug_cpu[0-7]$');
  static const _devices = {
    'cpu0',
    'cpu6',
    'gpu',
    'cpu-cluster0',
    'cpu-cluster1',
    'boost_limit',
  };
  static const _sensors = {
    'VIRTUAL-SENSOR-FORMULA',
    'VIRTUAL-SENSOR-FORMULA-FRONT',
    'VIRTUAL-SENSOR-FORMULA-BACK',
    'VIRTUAL-SENSOR-FORMULA-LEFT',
    'VIRTUAL-SENSOR-FORMULA-RIGHT',
    'VIRTUAL-SENSOR-FORMULA-TOP',
  };

  static ThermalProfileDraft build(
    String stock, {
    required int temperatureC,
    bool disabled = false,
  }) =>
      buildIfApplicable(
        stock,
        temperatureC: temperatureC,
        disabled: disabled,
      ) ??
      (throw const FormatException('No verified CPU/GPU thermal rules found.'));

  /// A valid scenario without selected performance rules needs no override.
  static ThermalProfileDraft? buildIfApplicable(
    String stock, {
    required int temperatureC,
    bool disabled = false,
  }) {
    if (temperatureC < 25 || temperatureC > 65) {
      throw const FormatException('Choose a temperature between 25 and 65 °C.');
    }
    if (stock.trim().isEmpty) {
      throw const FormatException(
        'Empty policy is not a stock thermal baseline.',
      );
    }
    final result = StringBuffer();
    final changed = <String>[];
    for (final section in stock.split(_section).where((s) => s.isNotEmpty)) {
      final lines = RegExp(
        r'[^\n]*\n|[^\n]+$',
      ).allMatches(section).map((m) => m.group(0)!).toList();
      final fields = <String, List<String>>{};
      for (final line in lines) {
        final content = line.trim();
        if (content.isEmpty ||
            content.startsWith('#') ||
            content.startsWith('[')) {
          continue;
        }
        final tokens = content.split(RegExp(r'\s+'));
        if (fields.containsKey(tokens.first)) {
          throw const FormatException('Duplicate keys in thermal section.');
        }
        fields[tokens.first] = tokens.skip(1).toList();
      }
      String first(String key, [String fallback = '']) =>
          fields[key]?.firstOrNull ?? fallback;
      final devices = first('device').split('+');
      final applicable =
          devices.every((d) => _devices.contains(d) || _hotplug.hasMatch(d)) &&
          _sensors.contains(first('sensor')) &&
          {'ss', 'monitor'}.contains(first('algo_type')) &&
          first('reverse', '0') == '0';
      if (!applicable) {
        result.write(section);
        continue;
      }
      final trigger = fields['trig']?.map(int.parse).toList();
      final clear = fields['clr']?.map(int.parse).toList();
      final targets = fields['target'];
      if (trigger == null ||
          clear == null ||
          targets == null ||
          trigger.isEmpty ||
          trigger.length != clear.length ||
          trigger.length != targets.length) {
        throw const FormatException('Inconsistent performance curve.');
      }
      for (var i = 0; i < trigger.length; i++) {
        if (trigger[i] <= 0 ||
            clear[i] >= trigger[i] ||
            (i > 0 && trigger[i] < trigger[i - 1])) {
          throw const FormatException('Invalid threshold ordering.');
        }
      }
      changed.add(lines.first.trim());
      if (disabled) continue;
      final delta = temperatureC * 1000 - trigger.first;
      final replacements = {
        'sensor': ['battery'],
        'trig': trigger.map((t) => '${t + delta}').toList(),
        'clr': clear.map((c) => '${c + delta}').toList(),
      };
      for (final line in lines) {
        final key = line.trim().split(RegExp(r'\s+')).first;
        if (!replacements.containsKey(key)) {
          result.write(line);
        } else {
          final end = line.endsWith('\r\n')
              ? '\r\n'
              : line.endsWith('\n')
              ? '\n'
              : '';
          result.write('$key\t${replacements[key]!.join('\t')}$end');
        }
      }
    }
    if (changed.isEmpty) return null;
    return ThermalProfileDraft(result.toString(), List.unmodifiable(changed));
  }
}
