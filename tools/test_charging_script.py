"""Run the phone script in a private fixture, never against host sysfs."""
from pathlib import Path
import os
import subprocess
import tarfile
import tempfile
import unittest


class ChargingScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='picters-charge-script-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'])
        source = Path(__file__).with_name('test-charging.sh').read_text()
        for prefix in ['/sys/', '/vendor_dlkm/', '/data/local/tmp/', '/sdcard/']:
            source = source.replace(prefix, str(self.root) + prefix)
        self.script = self.root / 'test.sh'
        self.script.write_text(source)
        for name in ['data/local/tmp', 'sdcard', 'sys/module/mca_strategy_buckchg']:
            (self.root / name).mkdir(parents=True)
        self.node = self.root / 'sys/class/xm_power/charger/charge_interface/iin_limit'
        self.node.parent.mkdir(parents=True)
        self.node.write_text('original')
        online = self.root / 'sys/class/power_supply/usb/online'
        online.parent.mkdir(parents=True)
        online.write_text('1')
        module = self.root / 'vendor_dlkm/lib/modules/mca_strategy_buckchg.ko'
        module.parent.mkdir(parents=True)
        module.write_text('fixture')
        self.stub('id', 'echo 0')
        self.stub('getprop', 'case "$1" in ro.product.device) echo pudding;; *) echo fixture;; esac')
        self.stub('sha256sum', 'echo ab9edb92cdd5a58d38ee4ae509435ab94b42587fea8004618998e9ad1fdb851c')
        self.stub('sleep', 'case "$1" in 45) exec /usr/bin/sleep 10;; *) exit 0;; esac')

    def stub(self, name, body):
        file = self.bin / name
        file.write_text('#!/bin/sh\n' + body + '\n')
        file.chmod(0o755)

    def run_script(self, *args):
        result = subprocess.run(['sh', str(self.script), *args], env=self.env,
                                text=True, capture_output=True, timeout=20)
        archives = list((self.root / 'sdcard').glob('*.tar.gz'))
        content = {}
        if archives:
            with tarfile.open(archives[0]) as archive:
                for member in archive.getmembers():
                    if member.isfile():
                        content[member.name.removeprefix('./')] = archive.extractfile(member).read().decode()
        return result, content

    def test_observe_never_writes_and_archives_telemetry(self):
        result, content = self.run_script('observe', '30')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.node.read_text(), 'original')
        self.assertNotIn('writes.txt', content)
        self.assertIn('observe 29', content['samples.txt'])

    def test_probe_releases_own_vote_and_records_both_phases(self):
        result, content = self.run_script('probe-buck')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.node.read_text().endswith(' buck 0\n'))
        self.assertIn('request_mA=500', content['writes.txt'])
        self.assertIn('request_mA=0', content['writes.txt'])
        self.assertIn('released 7', content['samples.txt'])

    def test_unknown_vendor_module_prevents_every_write(self):
        self.stub('sha256sum', 'echo wrong-hash')
        result, content = self.run_script('probe-buck')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.node.read_text(), 'original')
        self.assertNotIn('writes.txt', content)

    def test_failed_request_still_attempts_reset(self):
        self.stub('timeout', '''shift 3
case "$*" in *'buck 500'*) exit 1;; esac
exec "$@"''')
        result, content = self.run_script('probe-buck')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.node.read_text().endswith(' buck 0\n'))
        self.assertIn('request_mA=0', content['writes.txt'])


if __name__ == '__main__':
    unittest.main()
