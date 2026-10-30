"""Offline collector-analysis checks; no Android device or system paths used."""
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'thermal_archive', Path(__file__).with_name('analyze-thermal-archive.py'))
codec = importlib.util.module_from_spec(spec)
spec.loader.exec_module(codec)


class ThermalArchiveTests(unittest.TestCase):
    def test_codec_round_trip_and_corrupt_padding(self):
        for plain in (b'', b'[BAT_SOC]\nalgo_type\tsimulated\n'):
            encrypted = codec.crypt(plain, False)
            self.assertEqual(codec.crypt(encrypted, True), plain)
            self.assertEqual(len(encrypted) % 16, 0)
        self.assertIsNone(codec.crypt(b'broken', True))

    def test_loader_key_is_used_only_after_exact_validated_roundtrip(self):
        policy_key = bytes(range(16))
        plain = b'[BATTERY]\nalgo_type\tss\n'
        encrypted = codec.crypt(plain, False, policy_key.hex())
        with tempfile.TemporaryDirectory(prefix='picters-key-test-') as folder:
            root = Path(folder)
            archive = root / 'policy.tar'
            with tarfile.open(archive, 'w') as output:
                entry = tarfile.TarInfo('files/odm/thermal-normal.conf')
                entry.size = len(encrypted)
                output.addfile(entry, io.BytesIO(encrypted))
            without = codec.analyze(archive, root / 'without-key')
            self.assertEqual(without[0]['status'], 'unknown-codec')
            with_key = codec.analyze(archive, root / 'with-key', policy_key)
            self.assertEqual(with_key[0]['codec'], 'loader-derived')
            self.assertEqual(with_key[0]['status'], 'aes-cbc-text')
            self.assertEqual((root / 'with-key/decoded/files/odm/thermal-normal.conf').read_bytes(), plain)

    def test_archive_classification_preserves_unknown_and_rejects_traversal(self):
        with tempfile.TemporaryDirectory(prefix='picters-thermal-test-') as folder:
            root = Path(folder)
            archive = root / 'source.tar.gz'
            fixtures = {
                'files/data/normal.conf': codec.crypt(b'', False),
                'files/vendor/map.conf': codec.crypt(b'[0:thermal-normal.conf]\n', False),
                'files/odm/normal.conf': b'unknown-format!',
                '../../escape.conf': b'[must-not-write]',
                '/absolute.conf': b'[must-not-write]',
            }
            with tarfile.open(archive, 'w:gz') as output:
                for name, data in fixtures.items():
                    member = tarfile.TarInfo(name)
                    member.size = len(data)
                    output.addfile(member, io.BytesIO(data))
            records = codec.analyze(archive, root / 'result')
            self.assertEqual([r['status'] for r in records],
                             ['aes-cbc-empty', 'aes-cbc-text', 'unknown-codec'])
            self.assertFalse((root / 'escape.conf').exists())
            self.assertFalse((root / 'result/decoded/files/odm/normal.conf').exists())
            self.assertEqual((root / 'result/decoded/files/data/normal.conf').read_bytes(), b'')
            with tarfile.open(archive) as source:
                self.assertEqual(source.extractfile('files/odm/normal.conf').read(),
                                 fixtures['files/odm/normal.conf'])


if __name__ == '__main__':
    unittest.main()
