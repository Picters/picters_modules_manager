#!/usr/bin/env python3
"""Offline analysis only: classify and decrypt captured Xiaomi thermal policies."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

# Established Xiaomi config codec; a successful exact round trip is required.
KEY_HEX = b'thermalopenssl.h'.hex()


def crypt(data, decrypt, key_hex=KEY_HEX):
    args = ['openssl', 'enc', '-aes-128-cbc', '-K', key_hex, '-iv', key_hex]
    if decrypt:
        args.append('-d')
    result = subprocess.run(args, input=data, capture_output=True, timeout=10)
    return result.stdout if result.returncode == 0 else None


def readable(data):
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return False
    return all(c.isprintable() or c in '\n\r\t' for c in text)


def analyze(archive, output, extra_key=None):
    output.mkdir(parents=True, exist_ok=True)
    records = []
    with tarfile.open(archive) as source:
        for member in source:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or '..' in path.parts
                    or not member.name.endswith('.conf')):
                continue
            record = {'path': str(path), 'size': member.size}
            if member.size > 2 * 1024 * 1024:
                record['status'] = 'size-limit'
                records.append(record)
                continue
            raw = source.extractfile(member).read()
            record['sha256'] = hashlib.sha256(raw).hexdigest()
            if readable(raw) and (not raw or raw.lstrip().startswith((b'[', b'#'))):
                plain = raw
                record['status'] = 'plaintext'
            else:
                plain = None
                candidates = [('legacy', KEY_HEX)]
                if extra_key is not None:
                    if len(extra_key) != 16:
                        raise ValueError('Policy key must be exactly 16 bytes')
                    candidates.append(('loader-derived', extra_key.hex()))
                for variant, key_hex in candidates:
                    decoded = crypt(raw, True, key_hex) if raw and len(raw) % 16 == 0 else None
                    if (decoded is not None and readable(decoded)
                            and crypt(decoded, False, key_hex) == raw):
                        plain = decoded
                        record['codec'] = variant
                        break
                if plain is None:
                    record['status'] = 'unknown-codec'
                    records.append(record)
                    continue
                record['status'] = 'aes-cbc-empty' if not plain.strip() else 'aes-cbc-text'
            record['decoded_size'] = len(plain)
            target = output / 'decoded' / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(plain)
            records.append(record)
    (output / 'manifest.json').write_text(json.dumps(records, indent=2) + '\n')
    counts = {}
    for record in records:
        counts[record['status']] = counts.get(record['status'], 0) + 1
    print(json.dumps(counts, indent=2))
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--key-file', type=Path)
    args = parser.parse_args()
    analyze(args.archive, args.output, args.key_file.read_bytes() if args.key_file else None)
