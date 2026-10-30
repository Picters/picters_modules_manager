import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'thermal_profile', Path(__file__).with_name('build-thermal-profile.py'))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)

PERFORMANCE = '[SS-CPU0]\nalgo_type\tss\nsensor\tVIRTUAL-SENSOR-FORMULA\ndevice\tcpu0\ntrig\t25000\t35000\nclr\t23000\t33000\ntarget\t2745600\t1555200\n\n'
CHARGING = '[SIC-BAT]\nalgo_type\tsic\nsensor\tVIRTUAL-SENSOR-FORMULA\ndevice\tthermal_fcc_override\ntrig\t15000\t33000\nclr\t14000\t32000\ntarget\t0\t33500\n\n'
BCL = '[MONITOR-BCL]\nalgo_type\tmonitor\nsensor\tBAT_SOC\ndevice\tcpu0\ntrig\t1\t3\nclr\t2\t4\ntarget\t1324800\t1785600\nreverse\t1\n'


class ThermalProfileTests(unittest.TestCase):
    def test_battery_gate_preserves_hysteresis_targets_and_unrelated_rules(self):
        output, changes = profile.build(PERFORMANCE + CHARGING + BCL, 45)
        self.assertIn('sensor\tbattery\n', output)
        self.assertIn('trig\t45000\t55000\n', output)
        self.assertIn('clr\t43000\t53000\n', output)
        self.assertIn('target\t2745600\t1555200\n', output)
        self.assertTrue(output.endswith(CHARGING + BCL))
        self.assertEqual(len(changes), 1)

    def test_off_omits_only_custom_performance_rules(self):
        output, changes = profile.build(PERFORMANCE + CHARGING + BCL, 45, True)
        self.assertEqual(output, CHARGING + BCL)
        self.assertEqual(changes[0]['action'], 'omit-custom-performance-rule')

    def test_bad_curves_unknown_sensors_and_invalid_temperature_rejected(self):
        for temperature in [24, 66, 45.5]:
            with self.assertRaises(ValueError):
                profile.build(PERFORMANCE, temperature)
        with self.assertRaises(ValueError):
            profile.build(PERFORMANCE.replace('23000', '26000'), 45)
        with self.assertRaises(ValueError):
            profile.build(PERFORMANCE.replace('VIRTUAL-SENSOR-FORMULA', 'UNKNOWN'), 45)


if __name__ == '__main__':
    unittest.main()
