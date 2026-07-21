import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/perf_info.dart';
import 'package:picters_modules_manager/perf_repository.dart';

void main() {
  group('snapDownToAvailable', () {
    final avail = [1, 2, 3, 5, 8];

    test('picks the highest step <= target', () {
      expect(snapDownToAvailable(avail, 6), 5);
      expect(snapDownToAvailable(avail, 3), 3);
    });

    test('clamps to the lowest step when target is below all', () {
      expect(snapDownToAvailable(avail, 0), 1);
    });

    test('caps at the highest step when target is above all', () {
      expect(snapDownToAvailable(avail, 100), 8);
    });

    test('is order-independent (sorts internally)', () {
      expect(snapDownToAvailable([8, 1, 5, 2, 3], 6), 5);
    });
  });

  group('cappedMax — safety', () {
    // The real policy0 (6 cores) OPP table from the device.
    const p0 = [
      384000, 537600, 691200, 787200, 883200, 998400, 1113600, 1228800,
      1324800, 1440000, 1555200, 1670400, 1785600, 1900800, 1996800, 2112000,
      2227200, 2361600, 2496000, 2611200, 2745600, 2899200, 3033600, 3187200,
      3302400, 3398400, 3513600, 3628800,
    ];
    const stock = 3628800;

    test('Full returns exactly the stock max', () {
      expect(cappedMax(PerfProfile.full, stock, p0), stock);
    });

    test('Cool / Balanced snap down to a real OPP step below stock', () {
      expect(cappedMax(PerfProfile.cool, stock, p0), 2112000); // ~60%
      expect(cappedMax(PerfProfile.balanced, stock, p0), 2899200); // ~80%
    });

    test('never exceeds the stock max for any profile', () {
      for (final p in PerfProfile.values) {
        expect(cappedMax(p, stock, p0), lessThanOrEqualTo(stock));
      }
    });

    test('every capped value is a member of the OPP table (safe to write)', () {
      for (final p in PerfProfile.values) {
        expect(p0, contains(cappedMax(p, stock, p0)));
      }
    });

    test('empty OPP table falls back to stock (never writes a bogus value)', () {
      expect(cappedMax(PerfProfile.cool, stock, const []), stock);
    });
  });

  group('parsePerfScan', () {
    String scan({required String conf}) => '''
__PERF_CPU__
P:policy0|0 1 2 3 4 5|3628800|3628800|walt
F:policy0|384000 2112000 3628800
P:policy6|6 7|4608000|4608000|walt
F:policy6|768000 2668800 4608000
__PERF_GPU__
GAVAIL:160000000 539000000 902000000 1200000000
GMAX:902000000
__PERF_CONF__
$conf''';

    test('parses clusters, GPU and the persisted profile from config', () {
      final s = parsePerfScan(scan(conf: '''
enabled 1
profile cool
gpustock 902000000
cpu /sys/devices/system/cpu/cpufreq/policy0 2112000
gpu 539000000'''));

      expect(s.clusters, hasLength(2));
      final p0 = s.clusters.firstWhere((c) => c.policy == 'policy0');
      expect(p0.cpus, [0, 1, 2, 3, 4, 5]);
      expect(p0.maxHardware, 3628800);
      expect(p0.availableFreqs, contains(2112000));

      expect(s.gpu, isNotNull);
      expect(s.gpu!.currentMax, 902000000);
      expect(s.gpu!.stockMax, 902000000); // from config
      expect(s.profile, PerfProfile.cool);
      expect(s.persistOnBoot, isTrue);
    });

    test('with no config, GPU stock is captured from the live max', () {
      final s = parsePerfScan(scan(conf: ''));
      expect(s.gpu!.stockMax, 902000000); // live GMAX, first capture
      expect(s.profile, isNull);
      expect(s.persistOnBoot, isFalse);
    });

    test('prime cluster labels correctly against the set', () {
      final s = parsePerfScan(scan(conf: ''));
      final prime = s.clusters.firstWhere((c) => c.policy == 'policy6');
      final perf = s.clusters.firstWhere((c) => c.policy == 'policy0');
      expect(clusterLabel(prime, s.clusters), 'Prime cores');
      expect(clusterLabel(perf, s.clusters), 'Performance cores');
    });
  });
}
