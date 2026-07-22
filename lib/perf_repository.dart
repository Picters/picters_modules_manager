import 'perf_info.dart';
import 'root_shell.dart';

/// Config the boot service reads; lives outside /data/adb/modules so it
/// survives a module reinstall (same place as the boot-load flag).
const String kPerfConfigDir = '/data/adb/picters_modules_manager';
const String kPerfConfig = '$kPerfConfigDir/perf.conf';
const String kGpuMaxNode = '/sys/class/kgsl/kgsl-3d0/max_gpuclk';
const String _cpuBase = '/sys/devices/system/cpu/cpufreq';

/// The module's boot service — probed for the perf re-apply loop (it reads
/// perf.conf). An older module without it can't hold a cap, so the UI blocks
/// the performance controls until the module is updated.
const String kModuleService =
    '/data/adb/modules/picters-modules-pack/service.sh';

List<int> _parseFreqList(String s) => s
    .trim()
    .split(RegExp(r'\s+'))
    .map((t) => int.tryParse(t.trim()))
    .whereType<int>()
    .toList()
  ..sort();

/// Reads and applies CPU/GPU frequency caps over root. Every applied value is
/// snapped to a real OPP step by [cappedMax], so nothing unsafe is ever written.
class PerfRepository {
  PerfRepository([RootRunner runner = const DefaultRootRunner()])
      : _shell = runner;

  final RootRunner _shell;

  /// One root round-trip for the whole picture: every cpufreq policy, the GPU
  /// max + OPP table, and the persisted config (profile / persist flag / stock
  /// GPU ceiling).
  Future<PerfState> scan() async {
    final r = await _shell.run(
      'echo __PERF_CPU__; '
      'for p in $_cpuBase/policy*; do '
      'echo "P:\$(basename \$p)|\$(cat \$p/related_cpus 2>/dev/null)|'
      '\$(cat \$p/cpuinfo_max_freq 2>/dev/null)|\$(cat \$p/scaling_max_freq 2>/dev/null)|'
      '\$(cat \$p/scaling_governor 2>/dev/null)"; '
      'echo "F:\$(basename \$p)|\$(cat \$p/scaling_available_frequencies 2>/dev/null)"; '
      'done; '
      'echo __PERF_GPU__; '
      'echo "GAVAIL:\$(cat /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies 2>/dev/null)"; '
      'echo "GMAX:\$(cat $kGpuMaxNode 2>/dev/null)"; '
      'echo __PERF_CONF__; '
      'cat $kPerfConfig 2>/dev/null; '
      'echo __PERF_CAP__; '
      "grep -qF 'perf.conf' '$kModuleService' 2>/dev/null && echo PERF_BOOT_OK",
    );
    return parsePerfScan(r.stdout);
  }

  /// Applies [profile] live (writes each cluster's scaling_max_freq and the GPU
  /// max_gpuclk) and rewrites the boot config so the module can re-apply it.
  /// [persistOnBoot] gates whether the module actually does so at boot.
  Future<ShellResult> applyProfile({
    required PerfProfile profile,
    required PerfState state,
    required bool persistOnBoot,
  }) {
    final b = StringBuffer();
    final cpuLines = <String>[];
    for (final c in state.clusters) {
      final freq = cappedMax(profile, c.maxHardware, c.availableFreqs);
      final node = '$_cpuBase/${c.policy}/scaling_max_freq';
      b.writeln("echo $freq > '$node' 2>/dev/null");
      cpuLines.add('cpu $_cpuBase/${c.policy} $freq');
    }
    String? gpuLine;
    final gpu = state.gpu;
    if (gpu != null && gpu.stockMax > 0) {
      final gfreq = cappedMax(profile, gpu.stockMax, gpu.availableFreqs);
      b.writeln("echo $gfreq > '$kGpuMaxNode' 2>/dev/null");
      gpuLine = 'gpu $gfreq';
    }

    // Rewrite the boot config (append-built so no heredoc is needed inside the
    // framed root script).
    b.writeln("mkdir -p '$kPerfConfigDir'");
    b.writeln("C='$kPerfConfig'");
    b.writeln(': > "\$C"');
    b.writeln('echo "enabled ${persistOnBoot ? 1 : 0}" >> "\$C"');
    b.writeln('echo "profile ${profile.name}" >> "\$C"');
    if (gpu != null && gpu.stockMax > 0) {
      b.writeln('echo "gpustock ${gpu.stockMax}" >> "\$C"');
    }
    for (final l in cpuLines) {
      b.writeln('echo "$l" >> "\$C"');
    }
    if (gpuLine != null) b.writeln('echo "$gpuLine" >> "\$C"');
    b.writeln('echo OK_PERF');
    return _shell.run(b.toString(), timeout: const Duration(seconds: 20));
  }
}

/// Parses [PerfRepository.scan]'s output into a [PerfState]. Pure, so the scan
/// parsing is unit-testable without a device.
PerfState parsePerfScan(String out) {
  final lines = out.split('\n');
  var section = 0; // 0 pre, 1 cpu, 2 gpu, 3 conf
  final metaByPolicy = <String, List<String>>{}; // policy -> P fields
  final freqByPolicy = <String, List<int>>{};
  var gpuAvail = <int>[];
  var gpuMax = 0;
  final conf = <String, String>{};
  final confCpu = <String, int>{}; // policyPath -> freq (unused for state, kept simple)
  var bootOk = false;

  for (final raw in lines) {
    final line = raw.trim();
    if (line == '__PERF_CPU__') {
      section = 1;
      continue;
    }
    if (line == '__PERF_GPU__') {
      section = 2;
      continue;
    }
    if (line == '__PERF_CONF__') {
      section = 3;
      continue;
    }
    if (line == '__PERF_CAP__') {
      section = 4;
      continue;
    }
    switch (section) {
      case 1:
        if (line.startsWith('P:')) {
          final f = line.substring(2).split('|');
          if (f.isNotEmpty) metaByPolicy[f[0]] = f;
        } else if (line.startsWith('F:')) {
          final f = line.substring(2).split('|');
          if (f.length >= 2) freqByPolicy[f[0]] = _parseFreqList(f[1]);
        }
        break;
      case 2:
        if (line.startsWith('GAVAIL:')) {
          gpuAvail = _parseFreqList(line.substring(7));
        } else if (line.startsWith('GMAX:')) {
          gpuMax = int.tryParse(line.substring(5).trim()) ?? 0;
        }
        break;
      case 3:
        final sp = line.indexOf(' ');
        if (sp > 0) {
          final key = line.substring(0, sp);
          final val = line.substring(sp + 1).trim();
          if (key == 'cpu') {
            final parts = val.split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              confCpu[parts[0]] = int.tryParse(parts[1]) ?? 0;
            }
          } else {
            conf[key] = val;
          }
        }
        break;
      case 4:
        if (line == 'PERF_BOOT_OK') bootOk = true;
        break;
    }
  }

  final clusters = <CpuCluster>[];
  for (final entry in metaByPolicy.entries) {
    final f = entry.value; // [policy, related, cpuinfoMax, scalingMax, gov]
    final cpus = (f.length > 1 ? f[1] : '')
        .trim()
        .split(RegExp(r'\s+'))
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    clusters.add(CpuCluster(
      policy: entry.key,
      cpus: cpus,
      maxHardware: f.length > 2 ? (int.tryParse(f[2].trim()) ?? 0) : 0,
      scalingMax: f.length > 3 ? (int.tryParse(f[3].trim()) ?? 0) : 0,
      availableFreqs: freqByPolicy[entry.key] ?? const [],
      governor: f.length > 4 ? f[4].trim() : '',
    ));
  }
  clusters.sort((a, b) => a.policy.compareTo(b.policy));

  // Stock GPU ceiling: the config's captured value if present, else the live
  // max (first capture, before any cap was written).
  final confGpuStock = int.tryParse(conf['gpustock'] ?? '');
  final gpu = gpuAvail.isEmpty && gpuMax == 0
      ? null
      : GpuInfo(
          availableFreqs: gpuAvail,
          currentMax: gpuMax,
          stockMax: confGpuStock ?? gpuMax,
        );

  return PerfState(
    clusters: clusters,
    gpu: gpu,
    profile: PerfProfileX.fromName(conf['profile']),
    persistOnBoot: conf['enabled'] == '1',
    bootApplySupported: bootOk,
  );
}
