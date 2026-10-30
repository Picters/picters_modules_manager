#!/usr/bin/env python3
"""Cross-check Dart runtime and Python reference on every real scenario and degree."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('builder', Path(__file__).with_name('build-thermal-profile.py'))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('decoded_directory', type=Path)
parser.add_argument('--dart', default='dart')
parser.add_argument('--report', type=Path, required=True)
args = parser.parse_args()
command = [args.dart, str(Path(__file__).with_name('audit_thermal_range.dart')), str(args.decoded_directory)]
process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
verified = 0
scenarios = set()
for line in process.stdout:
    record = json.loads(line)
    stock = (args.decoded_directory / record['file']).read_text()
    expected, changes = builder.build(stock, record['temperature'], record['off'])
    assert record['text'] == expected, (record['file'], record['temperature'], record['off'])
    assert record['sections'] == [c['section'] for c in changes]
    unchanged = {s.splitlines()[0]: s for s in builder.sections(stock)}
    names = set(record['sections'])
    for section in builder.sections(expected):
        if section.splitlines()[0] not in names:
            assert section == unchanged[section.splitlines()[0]]
    verified += 1
    scenarios.add(record['file'])
if process.wait() != 0:
    raise RuntimeError('Dart profile audit failed')
assert verified == len(scenarios) * 42
result = {'scenarios': len(scenarios), 'temperature_range': [25, 65],
          'temperature_step': 1, 'off_included': True,
          'cross_checked_variants': verified, 'runtime_device_verified': False}
args.report.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
