#!/usr/bin/env python3
"""Build an offline Xiaomi CPU/GPU thermal profile draft. Never deploys to a device.

Requires a validated, decoded stock profile. Preserve charging, RF, battery-level,
hardware emergency and unrelated rules. Export must still be tested on hardware.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

PERFORMANCE_DEVICES = {'cpu0', 'cpu6', 'gpu', 'cpu-cluster0', 'cpu-cluster1', 'boost_limit'}


def sections(text):
    parts = re.split(r'(?m)(?=^\[[^\]\r\n]+\][ \t]*\r?$)', text)
    return [p for p in parts if p]


def fields(section):
    return {tokens[0]: tokens[1:] for line in section.splitlines()
            if (tokens := line.split()) and not line.lstrip().startswith(('#', '['))}


def build(text, threshold, disabled=False):
    if not 25 <= threshold <= 65 or int(threshold) != threshold:
        raise ValueError('Choose a whole-degree threshold between 25 and 65')
    if not text.strip():
        raise ValueError('Empty policy is not a stock thermal baseline')
    edited, changes = [], []
    for section in sections(text):
        f = fields(section)
        keys = [line.split()[0] for line in section.splitlines()
                if line.split() and not line.lstrip().startswith(('#', '['))]
        if len(keys) != len(set(keys)):
            raise ValueError('Duplicate keys in thermal section')
        devices = f.get('device', [''])[0].split('+')
        sensor = f.get('sensor', [''])[0]
        # Mixed devices and non-temperature sensors must remain untouched.
        # This prevents BAT_SOC, TEMP_AWARE, SPECIAL_CPU_LIMIT and charging edits.
        if (not devices or not all(d in PERFORMANCE_DEVICES or re.fullmatch(r'hotplug_cpu[0-7]', d) for d in devices)
                or sensor not in {
                    'VIRTUAL-SENSOR-FORMULA', 'VIRTUAL-SENSOR-FORMULA-FRONT',
                    'VIRTUAL-SENSOR-FORMULA-BACK', 'VIRTUAL-SENSOR-FORMULA-LEFT',
                    'VIRTUAL-SENSOR-FORMULA-RIGHT', 'VIRTUAL-SENSOR-FORMULA-TOP',
                }
                or f.get('algo_type') not in (['ss'], ['monitor'])
                or f.get('reverse', ['0']) != ['0']):
            edited.append(section)
            continue
        name = section.splitlines()[0]
        if not all(k in f for k in ('sensor', 'trig', 'clr', 'target')):
            raise ValueError(f'Incomplete performance rule: {name}')
        trig, clear = [list(map(int, f[k])) for k in ('trig', 'clr')]
        if not trig or len(trig) != len(clear) or len(trig) != len(f['target']):
            raise ValueError(f'Inconsistent performance curve: {name}')
        if (any(c >= t for c, t in zip(clear, trig))
                or any(t <= 0 for t in trig)
                or trig != sorted(trig)) :
            raise ValueError(f'Invalid threshold ordering: {name}')
        if disabled:
            changes.append({'section': name, 'action': 'omit-custom-performance-rule'})
            continue
        delta = int(threshold) * 1000 - trig[0]
        replacements = {
            'sensor': ['battery'],
            'trig': [str(t + delta) for t in trig],
            'clr': [str(c + delta) for c in clear],
        }
        lines = []
        for line in section.splitlines(keepends=True):
            tokens = line.split()
            if tokens and tokens[0] in replacements:
                newline = '\r\n' if line.endswith('\r\n') else '\n' if line.endswith('\n') else ''
                line = tokens[0] + '\t' + '\t'.join(replacements[tokens[0]]) + newline
            lines.append(line)
        edited.append(''.join(lines))
        changes.append({'section': name, 'action': 'battery-gated',
                        'first_trigger_mC': int(threshold) * 1000,
                        'last_trigger_mC': trig[-1] + delta})
    if not changes:
        raise ValueError('No verified CPU/GPU thermal rules found')
    return ''.join(edited), changes


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stock', type=Path)
    parser.add_argument('--temperature', type=int, required=True)
    parser.add_argument('--off', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--key-file', type=Path, required=True)
    args = parser.parse_args()
    raw = args.stock.read_bytes()
    text, changes = build(raw.decode('utf-8'), args.temperature, args.off)
    key = args.key_file.read_bytes()
    if len(key) != 16:
        raise ValueError('Thermal profile key must be 16 bytes')
    args.output.mkdir(parents=True, exist_ok=False)
    plain = text.encode('utf-8')
    plain_file = args.output / 'thermal-normal.plain.conf'
    plain_file.write_bytes(plain)
    command = ['openssl', 'enc', '-aes-128-cbc', '-K', key.hex(), '-iv', key.hex()]
    encrypted = subprocess.run(command, input=plain, capture_output=True, check=True).stdout
    roundtrip = subprocess.run(command + ['-d'], input=encrypted, capture_output=True, check=True).stdout
    if roundtrip != plain:
        raise ValueError('Encrypted profile failed round-trip validation')
    (args.output / 'thermal-normal.conf').write_bytes(encrypted)
    (args.output / 'manifest.json').write_text(json.dumps({
        'device_deployment_verified': False,
        'scope': 'CPU/GPU vendor rules only; other thermal protections remain active',
        'stock_sha256': hashlib.sha256(raw).hexdigest(),
        'threshold_c': args.temperature,
        'off': args.off,
        'changes': changes,
    }, indent=2) + '\n')
    print(f'Built draft with {len(changes)} performance-rule changes; encryption verified.')
