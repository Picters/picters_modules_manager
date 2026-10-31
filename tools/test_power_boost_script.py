"""Run the actual probe against an isolated emulation of the captured command ABI."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest


class PowerBoostProbeTests(unittest.TestCase):
    def test_original_feature_is_restored_without_changing_other_features(self):
        for original in [18, 22]:
            with self.subTest(original=original):
                self.run_probe(original)

    def test_unverified_vendor_never_receives_a_write(self):
        self.run_probe(18, supported=False)

    def test_rejected_enable_rolls_back_and_returns_failure(self):
        self.run_probe(18, rejected=True)

    def run_probe(self, original, supported=True, rejected=False):
        with tempfile.TemporaryDirectory(prefix='picters-boost-probe-test-') as tmp:
            root = Path(tmp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            node = root / 'smart_chg'
            node.write_text(str(original))
            commands = root / 'commands'
            def stub(name, text):
                path = bin_dir / name
                path.write_text('#!/bin/sh\n' + text + '\n')
                path.chmod(0o755)
            stub('id', 'echo 0')
            stub('getprop', 'case "$1" in ro.product.device) echo pudding;; *) echo fixture;; esac')
            expected = 'bc9321a44fb892f77c18739e83fbe956a06974f4a9946cf16ac01db1f2d605d7'
            stub('sha256sum', 'echo ' + (expected if supported else 'unsupported'))
            stub('dumpsys', 'echo mWakefulness=Awake')
            stub('uname', 'echo fixture-kernel')
            stub('sleep', 'case "$1" in 90) exec /bin/sleep 3;; *) exec /bin/sleep 0.001;; esac')
            source = (Path(__file__).parent / 'test-power-boost.sh').read_text()
            source = source.replace('BOOST_NODE=/sys/class/xm_power/charger/smart_charge/smart_chg', f'BOOST_NODE={node}')
            source = source.replace('/data/local/tmp/', str(root) + '/').replace('/sdcard/', str(root) + '/')
            source = source.replace('  bounded sh -c \'printf "%s\\n" "$2" > "$1"\' sh "$BOOST_NODE" "$1"', '''  printf '%s\\n' "$1" >> "''' + str(commands) + '''"
  old=$(cat "$BOOST_NODE")
  case "$1" in
    5) ''' + ('return 1' if rejected else 'printf "%s\\n" "$((old | 4))" > "$BOOST_NODE"') + ''';;
    4) printf '%s\\n' "$((old & ~4))" > "$BOOST_NODE";;
    *) return 1;;
  esac''')
            # All telemetry paths are empty fixture paths; no host sysfs reads.
            source = source.replace('/sys/class/power_supply/', str(root / 'supplies') + '/')
            source = source.replace('/sys/class/xm_power/', str(root / 'xm_power') + '/')
            script = root / 'probe.sh'
            script.write_text(source)
            result = subprocess.run(['sh', str(script)], env=dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH']), capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode == 0, supported and not rejected, result.stderr)
            self.assertEqual(int(node.read_text()), original)
            if not supported:
                self.assertFalse(commands.exists())
            else:
                self.assertEqual(commands.read_text().splitlines()[-1], '5' if original & 4 else '4')
                self.assertIn('Saved:', result.stdout)


if __name__ == '__main__':
    unittest.main()
