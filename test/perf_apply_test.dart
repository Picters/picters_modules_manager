import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/perf_info.dart';
import 'package:picters_modules_manager/perf_repository.dart';
import 'package:picters_modules_manager/root_shell.dart';

class SysfsRunner implements RootRunner {
  SysfsRunner(this.dir, {this.ignoreCap = false});
  final Directory dir;
  final bool ignoreCap;
  @override
  Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    script = script
        .replaceAll(kGpuMaxNode, '${dir.path}/gpu')
        .replaceAll(kPerfConfigDir, '${dir.path}/config');
    // Emulate KGSL: reads aggregate the requested ceiling with thermal limits.
    final cat =
        '''cat() {
      if [ "\$1" = '${dir.path}/gpu' ]; then
        req=\$(/bin/cat "\$1")
        if [ '${ignoreCap ? 1 : 0}' = 1 ] || [ "\$req" -gt 902000000 ]; then
          echo 902000000
        else /bin/cat "\$1"; fi
      else /bin/cat "\$@"; fi
    }
''';
    final result = await Process.run('sh', ['-c', cat + script]);
    return ShellResult(result.exitCode, '${result.stdout}${result.stderr}');
  }
}

void main() {
  late Directory dir;
  const state = PerfState(
    clusters: [],
    gpu: GpuInfo(
      availableFreqs: [160000000, 342000000, 902000000, 1200000000],
      currentMax: 902000000,
      stockMax: 1200000000,
    ),
    profile: PerfProfile.full,
    persistOnBoot: false,
    bootApplySupported: true,
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('picters-perf-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  test(
    'Ultra to Full restores the request despite a lower thermal readback',
    () async {
      final repo = PerfRepository(SysfsRunner(dir));
      for (final profile in [PerfProfile.ultraEco, PerfProfile.full]) {
        final result = await repo.applyProfile(
          profile: profile,
          state: state,
          persistOnBoot: false,
        );
        expect(result.ok, isTrue, reason: result.stdout);
        expect(result.stdout, contains('OK_PERF'));
      }
      expect(await File('${dir.path}/gpu').readAsString(), '1200000000\n');
      final config = await File('${dir.path}/config/perf.conf').readAsString();
      expect(config, contains('profile full\n'));
      expect(config, contains('gpu 1200000000\n'));
    },
  );
  test(
    'an ignored downward cap still fails and does not save the profile',
    () async {
      final repo = PerfRepository(SysfsRunner(dir, ignoreCap: true));
      final result = await repo.applyProfile(
        profile: PerfProfile.ultraEco,
        state: state,
        persistOnBoot: false,
      );
      expect(result.ok, isFalse);
      expect(result.stdout, contains('GPU did not apply'));
      expect(await File('${dir.path}/config/perf.conf').exists(), isFalse);
    },
  );
}
