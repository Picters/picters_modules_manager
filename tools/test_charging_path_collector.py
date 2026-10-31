"""Smoke-test the actual read-only collector on an isolated Android filesystem."""
from pathlib import Path
import os
import subprocess
import tarfile
import tempfile
import unittest


class ChargingPathCollectorTests(unittest.TestCase):
    def test_records_policy_and_display_state_without_changing_controls(self):
        with tempfile.TemporaryDirectory(prefix='picters-charging-path-') as tmp:
            root = Path(tmp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            def put(path, value):
                file = root / path.lstrip('/')
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(value)
                return file
            controls = [
                put('/sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit', '14\n'),
                put('/sys/class/xm_power/charger/smart_charge/smart_chg', '64\n'),
                put('/data/adb/picters_modules_manager/charging/policy', '120\n1\nfixture\n'),
            ]
            put('/sys/class/power_supply/battery/temp', '420\n')
            put('/sys/firmware/devicetree/base/soc/mca_charger/thermal_limit', 'fixture-curve')
            put('/sys/firmware/devicetree/base/soc/mca_charger/serial-number', 'must-not-copy')
            put('/odm/etc/thermal-normal.conf', '[fixture-policy]\n')
            put('/vendor_dlkm/lib/modules/mi_thermal_interface.ko', 'fixture-binary-not-executable')
            (root / 'data/local/tmp').mkdir(parents=True)
            (root / 'sdcard').mkdir()
            def stub(name, body):
                p = bin_dir / name
                p.write_text('#!/bin/sh\n' + body + '\n')
                p.chmod(0o755)
            stub('id', 'echo 0')
            stub('getprop', 'echo fixture')
            stub('dumpsys', 'case "$1" in power) echo mWakefulness=Awake;; *) echo versionCode=18;; esac')
            stub('logcat', 'echo "fixture micharge policy log"')
            stub('dmesg', 'echo "fixture mca_charger_thermal log"')
            stub('seq', "printf '1\\n2\\n'")
            stub('sleep', ':')
            source = (Path(__file__).parent / 'collect-charging-path.sh').read_text()
            for prefix in ['/sys/', '/data/', '/sdcard/', '/vendor/', '/vendor_dlkm/', '/odm/']:
                source = source.replace(prefix, str(root) + prefix)
            script = root / 'collector.sh'
            script.write_text(source)
            before = {p: p.read_bytes() for p in controls}
            result = subprocess.run(['sh', str(script)], env=dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH']), capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            for path, original in before.items():
                self.assertEqual(path.read_bytes(), original)
            archive, = (root / 'sdcard').glob('*.tar.gz')
            with tarfile.open(archive) as t:
                names = t.getnames()
                self.assertTrue(any('thermal_limit' in n for n in names))
                self.assertFalse(any('serial-number' in n for n in names))
                samples = t.extractfile('./samples.txt').read().decode()
                self.assertIn('mWakefulness=Awake', samples)
                self.assertIn('wired_ctrl_limit=14', samples)
                self.assertIn('smart_chg=64', samples)
            self.assertEqual(list((root / 'data/local/tmp').iterdir()), [])


if __name__ == '__main__':
    unittest.main()
