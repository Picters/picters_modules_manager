import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/perf_info.dart';
import 'package:picters_modules_manager/perf_repository.dart';
import 'package:picters_modules_manager/root_shell.dart';

class _FakeDevice implements RootRunner {
  _FakeDevice(this.root);
  final Directory root;
  bool ignoreGovernor = false;
  bool ignoreGpuMinimum = false;
  String map(String value) => value
      .replaceAll('/sys/devices/system/cpu/cpufreq', '${root.path}/cpu')
      .replaceAll('/sys/class/kgsl/kgsl-3d0', '${root.path}/gpu')
      .replaceAll('/sys/kernel/picters_perf', '${root.path}/picters_perf')
      .replaceAll(kPerfConfigDir, '${root.path}/config')
      .replaceAll(kModuleService, '${root.path}/service.sh');
  Future<void> put(String path, String value) async {
    final file = File(map(path));
    await file.parent.create(recursive: true);
    await file.writeAsString('$value\n');
  }

  Future<String> read(String path) async => File(map(path)).readAsString();
  @override
  Future<ShellResult> run(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final override = (ignoreGovernor || ignoreGpuMinimum)
        ? '''cat() {
      case "\$1" in
        */scaling_governor) ${ignoreGovernor ? 'echo walt' : '/bin/cat "\$@"'} ;;
        */devfreq/min_freq) ${ignoreGpuMinimum ? 'echo 100000000' : '/bin/cat "\$@"'} ;;
        *) /bin/cat "\$@" ;;
      esac
    }
'''
        : '';
    final r = await Process.run('sh', ['-c', override + map(script)]);
    return ShellResult(r.exitCode, '${r.stdout}${r.stderr}');
  }
}

void main() {
  late _FakeDevice device;
  late PerfRepository repo;
  const cpu = '/sys/devices/system/cpu/cpufreq/policy0';
  setUp(() async {
    device = _FakeDevice(await Directory.systemTemp.createTemp('pmm-gaming-'));
    repo = PerfRepository(device);
    for (final entry in {
      '$cpu/related_cpus': '0 1 2 3',
      '$cpu/cpuinfo_max_freq': '3000000',
      '$cpu/scaling_max_freq': '3000000',
      '$cpu/scaling_min_freq': '300000',
      '$cpu/scaling_available_frequencies': '300000 900000 1800000 3000000',
      '$cpu/scaling_governor': 'walt',
      '$cpu/scaling_available_governors': 'walt performance schedutil',
      '/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies':
          '100000000 200000000 400000000',
      kGpuMaxNode: '400000000',
      '$kGpuDevfreq/governor': 'msm-adreno-tz',
      '$kGpuDevfreq/available_governors': 'msm-adreno-tz performance',
      '$kGpuDevfreq/min_freq': '100000000',
      kModuleService: '# perf.conf PMM_PERF_V2',
    }.entries) {
      await device.put(entry.key, entry.value);
    }
  });
  tearDown(() => device.root.delete(recursive: true));

  Future<PerfState> profile(PerfProfile profile, PerfState state) async {
    final r = await repo.applyProfile(
      profile: profile,
      state: state,
      persistOnBoot: false,
    );
    expect(r.ok, isTrue, reason: r.stdout);
    expect(r.stdout, contains('OK_PERF'));
    return repo.scan();
  }

  Future<PerfState> lock(bool value, PerfState state) async {
    final r = await repo.setFrequencyLock(
      locked: value,
      state: state,
      persistOnBoot: false,
    );
    expect(r.ok, isTrue, reason: r.stdout);
    return repo.scan();
  }

  test(
    'Gaming changes governors, locks stay independent and originals restore',
    () async {
      var state = await repo.scan();
      expect(state.gamingSupported, isTrue);
      expect(state.frequencyLockSupported, isTrue);
      state = await profile(PerfProfile.gaming, state);
      expect(state.gamingActive, isTrue);
      expect(state.frequenciesLocked, isFalse);
      expect(await device.read('$cpu/scaling_min_freq'), '300000\n');
      expect(await device.read('$kGpuDevfreq/min_freq'), '100000000\n');

      state = await lock(true, state);
      expect(state.lockActive, isTrue);
      expect(await device.read('$cpu/scaling_min_freq'), '3000000\n');
      state = await profile(PerfProfile.balanced, state);
      expect(state.lockActive, isTrue);
      expect(state.gamingActive, isFalse);
      expect(await device.read('$cpu/scaling_governor'), 'walt\n');
      expect(await device.read('$kGpuDevfreq/governor'), 'msm-adreno-tz\n');
      expect(await device.read('$cpu/scaling_min_freq'), '1800000\n');
      expect(await device.read('$cpu/scaling_max_freq'), '1800000\n');

      state = await lock(false, state);
      expect(state.frequenciesLocked, isFalse);
      expect(await device.read('$cpu/scaling_min_freq'), '300000\n');
      expect(await device.read('$kGpuDevfreq/min_freq'), '100000000\n');
      expect(await device.read(kPerfOriginals), isEmpty);
      // A new session captures changed vendor defaults, not the prior session.
      await device.put('$cpu/scaling_governor', 'schedutil');
      state = await profile(PerfProfile.gaming, await repo.scan());
      await profile(PerfProfile.full, state);
      expect(await device.read('$cpu/scaling_governor'), 'schedutil\n');
    },
  );

  test('unsupported GPU governor remains untouched and is reported', () async {
    await device.put('$kGpuDevfreq/available_governors', 'msm-adreno-tz');
    var state = await repo.scan();
    expect(state.unsupportedGamingDomains, ['GPU']);
    state = await profile(PerfProfile.gaming, state);
    expect(state.gamingActive, isTrue);
    expect(await device.read('$kGpuDevfreq/governor'), 'msm-adreno-tz\n');
  });

  test(
    'rejected governor rolls all previous writes back without saving a profile',
    () async {
      await device.put('$cpu/scaling_max_freq', '1800000');
      device.ignoreGovernor = true;
      final r = await repo.applyProfile(
        profile: PerfProfile.gaming,
        state: await repo.scan(),
        persistOnBoot: false,
      );
      expect(r.ok, isFalse);
      expect(r.stdout, contains('Control did not apply'));
      expect(await device.read('$cpu/scaling_max_freq'), '1800000\n');
      expect(await device.read('$cpu/scaling_governor'), 'walt\n');
      expect(await File(device.map(kPerfConfig)).exists(), isFalse);
    },
  );

  test(
    'kernel floors are independent and released explicitly on unlock',
    () async {
      await device.put(kKernelCpuMaxNode, '0:0');
      await device.put(kKernelCpuMinNode, '0:0');
      await device.put(kKernelProfileNode, 'full');
      var state = await repo.scan();
      expect(state.kernelLocksSupported, isTrue);
      state = await lock(true, state);
      expect(await device.read(kKernelCpuMinNode), '0:3000000\n');
      expect(await device.read(kPerfConfig), contains('kmin 0:3000000\n'));
      await lock(false, state);
      expect(await device.read(kKernelCpuMinNode), '0:0\n');
    },
  );

  test(
    'request and verified live lock state differ when vendor changed a minimum',
    () async {
      final state = await lock(true, await repo.scan());
      expect(state.lockActive, isTrue);
      await device.put('$cpu/scaling_min_freq', '300000');
      final changed = await repo.scan();
      expect(changed.frequenciesLocked, isTrue);
      expect(changed.lockActive, isFalse);
    },
  );

  test(
    'boot persistence requires new service capability before any writes',
    () async {
      await device.put(kModuleService, '# perf.conf');
      final r = await repo.applyProfile(
        profile: PerfProfile.gaming,
        state: await repo.scan(),
        persistOnBoot: true,
      );
      expect(r.ok, isFalse);
      expect(r.stdout, contains('Update SystemPack'));
      expect(await device.read('$cpu/scaling_governor'), 'walt\n');
    },
  );
  test(
    'sparse QoS rollback explicitly releases each newly requested policy',
    () async {
      const p6 = '/sys/devices/system/cpu/cpufreq/policy6';
      for (final entry in {
        '$p6/related_cpus': '6 7',
        '$p6/cpuinfo_max_freq': '3000000',
        '$p6/scaling_max_freq': '3000000',
        '$p6/scaling_min_freq': '300000',
        '$p6/scaling_available_frequencies': '300000 900000 1800000 3000000',
        '$p6/scaling_governor': 'walt',
        '$p6/scaling_available_governors': 'walt performance',
        kKernelCpuMaxNode: '0:1000000',
        kKernelCpuMinNode: '0:900000',
        kKernelProfileNode: 'balanced',
        kPerfConfig: 'enabled 0\nprofile balanced\nlock 0',
      }.entries) {
        await device.put(entry.key, entry.value);
      }
      device.ignoreGpuMinimum = true;
      final r = await repo.setFrequencyLock(
        locked: true,
        state: await repo.scan(),
        persistOnBoot: false,
      );
      expect(r.ok, isFalse);
      expect(r.stdout, contains('Control did not apply'));
      // Real driver writes update only named policies. A sparse "0:1000000"
      // rollback would leave the newly added policy6 request behind.
      expect((await device.read(kKernelCpuMaxNode)).trim(), '0:1000000 6:0');
      expect((await device.read(kKernelCpuMinNode)).trim(), '0:900000 6:0');
      final requests = <int, int>{0: 1800000, 6: 1800000};
      for (final pair in (await device.read(
        kKernelCpuMinNode,
      )).trim().split(RegExp(r'\s+'))) {
        final parts = pair.split(':');
        requests[int.parse(parts[0])] = int.parse(parts[1]);
      }
      expect(requests, {0: 900000, 6: 0});
      expect(
        await device.read(kPerfConfig),
        'enabled 0\nprofile balanced\nlock 0\n',
      );
    },
  );

  test(
    'service and app share one mutex through reads, writes and restoration',
    () async {
      var state = await repo.scan();
      var r = await repo.applyProfile(
        profile: PerfProfile.gaming,
        state: state,
        persistOnBoot: true,
      );
      expect(r.ok, isTrue, reason: r.stdout);
      state = await repo.scan();
      r = await repo.setFrequencyLock(
        locked: true,
        state: state,
        persistOnBoot: true,
      );
      expect(r.ok, isTrue, reason: r.stdout);
      state = await repo.scan();

      final reference = await File('docs/perf_boot_service.sh').readAsString();
      final definitions = reference
          .split('\npmm_apply_perf\n( sleep 20;')
          .first;
      final held = File('${device.root.path}/service-has-lock');
      final release = File('${device.root.path}/release-service');
      final service = await Process.start('sh', [
        '-c',
        device.map('''
$definitions
pmm_apply_kernel_caps() {
  echo held > '${held.path}'
  while [ ! -f '${release.path}' ]; do sleep 0.02; done
}
pmm_apply_perf
'''),
      ]);
      final output = service.stdout.drain<void>();
      final errors = service.stderr.drain<void>();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!await held.exists() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        await held.exists(),
        isTrue,
        reason: 'service must hold the shared mutex',
      );
      final restoreState = PerfState(
        clusters: state.clusters,
        gpu: state.gpu,
        profile: state.profile,
        persistOnBoot: state.persistOnBoot,
        bootApplySupported: state.bootApplySupported,
        kernelCapsSupported: state.kernelCapsSupported,
        kernelLocksSupported: state.kernelLocksSupported,
        advancedBootSupported: state.advancedBootSupported,
        frequenciesLocked: false,
      );
      var finished = false;
      final restore = repo
          .applyProfile(
            profile: PerfProfile.full,
            state: restoreState,
            persistOnBoot: false,
          )
          .whenComplete(() => finished = true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        finished,
        isFalse,
        reason: 'app must wait while the service owns the mutex',
      );
      expect(await device.read(kPerfConfig), contains('profile gaming\n'));
      expect(await device.read('$cpu/scaling_governor'), 'performance\n');
      await release.writeAsString('go');
      expect(await service.exitCode, 0);
      await output;
      await errors;
      final result = await restore;
      expect(result.ok, isTrue, reason: result.stdout);
      expect(await device.read('$cpu/scaling_governor'), 'walt\n');
      expect(await device.read('$kGpuDevfreq/governor'), 'msm-adreno-tz\n');
      expect(await device.read('$cpu/scaling_min_freq'), '300000\n');
      expect(await device.read('$kGpuDevfreq/min_freq'), '100000000\n');
      expect(await device.read(kPerfConfig), contains('profile full\n'));
      expect(
        await Directory(device.map('$kPerfConfigDir/perf-apply.lock')).exists(),
        isFalse,
      );
    },
  );

  test('dead mutex owner is recovered before applying a profile', () async {
    final mutex = Directory(device.map('$kPerfConfigDir/perf-apply.lock'));
    await mutex.create(recursive: true);
    await File('${mutex.path}/owner').writeAsString('99999999 0\n');
    await profile(PerfProfile.gaming, await repo.scan());
    expect(await mutex.exists(), isFalse);
  });
  test('live reused PID from another boot cannot keep a stale mutex', () async {
    final mutex = Directory(device.map('$kPerfConfigDir/perf-apply.lock'));
    await mutex.create(recursive: true);
    await File(
      '${mutex.path}/owner',
    ).writeAsString('$pid 0 different-boot-id 1\n');
    await profile(PerfProfile.gaming, await repo.scan());
    expect(await mutex.exists(), isFalse);
  });

  test('same-boot PID reuse is detected by its process starttime', () async {
    final bootId = (await File(
      '/proc/sys/kernel/random/boot_id',
    ).readAsString()).trim();
    final mutex = Directory(device.map('$kPerfConfigDir/perf-apply.lock'));
    await mutex.create(recursive: true);
    await File(
      '${mutex.path}/owner',
    ).writeAsString('$pid 0 $bootId impossible-starttime\n');
    await profile(PerfProfile.gaming, await repo.scan());
    expect(await mutex.exists(), isFalse);
  });
}
