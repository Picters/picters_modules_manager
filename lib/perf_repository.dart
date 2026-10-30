import 'perf_info.dart';
import 'root_shell.dart';

/// Config the boot service reads; lives outside /data/adb/modules so it
/// survives a module reinstall (same place as the boot-load flag).
const String kPerfConfigDir = '/data/adb/picters_modules_manager';
const String kPerfConfig = '$kPerfConfigDir/perf.conf';
const String kGpuMaxNode = '/sys/class/kgsl/kgsl-3d0/max_gpuclk';
const String kPerfOriginals = '$kPerfConfigDir/perf-originals.conf';
const String kGpuDevfreq = '/sys/class/kgsl/kgsl-3d0/devfreq';
const String _cpuBase = '/sys/devices/system/cpu/cpufreq';

/// The module's boot service — probed for the perf re-apply loop (it reads
/// perf.conf). An older module without it can't hold a cap, so the UI blocks
/// the performance controls until the module is updated.
const String kModuleService =
    '/data/adb/modules/picters-modules-pack/service.sh';

/// In-kernel per-policy FREQ_QOS ceilings (CONFIG_PICTERS_PERF). Unlike a write
/// to scaling_max_freq, the vendor perf HAL can't raise these back, so a cap
/// holds on its own. Absent on older kernels — then the module's re-apply loop
/// is what keeps the ceiling, and the deepest profiles are less reliable.
const String kKernelPerfDir = '/sys/kernel/picters_perf';
const String kKernelCpuMaxNode = '$kKernelPerfDir/cpu_max_freq';
const String kKernelCpuMinNode = '$kKernelPerfDir/cpu_min_freq';
const String kKernelProfileNode = '$kKernelPerfDir/profile';

List<int> _parseFreqList(String s) =>
    s
        .trim()
        .split(RegExp(r'\s+'))
        .map((t) => int.tryParse(t.trim()))
        .whereType<int>()
        .where((f) => f > 0)
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
      'echo "D:\$(basename \$p)|\$(cat \$p/scaling_min_freq 2>/dev/null)|'
      '\$(cat \$p/scaling_available_governors 2>/dev/null)|'
      '\$([ -w \$p/scaling_governor ] && echo 1)|'
      '\$([ -w \$p/scaling_min_freq ] && echo 1)"; '
      'done; '
      'echo __PERF_GPU__; '
      'echo "GAVAIL:\$(cat /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies 2>/dev/null)"; '
      'echo "GMAX:\$(cat $kGpuMaxNode 2>/dev/null)"; '
      'echo "GGOV:\$(cat $kGpuDevfreq/governor 2>/dev/null)|'
      '\$(cat $kGpuDevfreq/available_governors 2>/dev/null)|'
      '\$([ -w $kGpuDevfreq/governor ] && echo 1)"; '
      'echo "GMIN:\$(cat $kGpuDevfreq/min_freq 2>/dev/null)|'
      '\$([ -w $kGpuDevfreq/min_freq ] && echo 1)"; '
      'echo __PERF_CONF__; '
      'cat $kPerfConfig 2>/dev/null; '
      'echo __PERF_CAP__; '
      "grep -qF 'perf.conf' '$kModuleService' 2>/dev/null && echo PERF_BOOT_OK; "
      "[ -w '$kKernelCpuMaxNode' ] && echo PERF_KERNEL_OK; "
      "[ -w '$kKernelCpuMinNode' ] && echo PERF_KERNEL_MIN_OK; "
      "grep -qF 'PMM_PERF_V2' '$kModuleService' 2>/dev/null && echo PERF_ADVANCED_OK",
    );
    return parsePerfScan(r.stdout);
  }

  /// Apply stock-bounded ceilings and, for Gaming, supported performance
  /// governors. Minimum-frequency locking is an independent request.
  Future<ShellResult> applyProfile({
    required PerfProfile profile,
    required PerfState state,
    required bool persistOnBoot,
  }) => _apply(
    profile: profile,
    state: state,
    persistOnBoot: persistOnBoot,
    lockFrequencies: state.frequenciesLocked,
  );

  Future<ShellResult> setFrequencyLock({
    required bool locked,
    required PerfState state,
    required bool persistOnBoot,
  }) => _apply(
    profile: state.profile ?? PerfProfile.full,
    state: state,
    persistOnBoot: persistOnBoot,
    lockFrequencies: locked,
  );

  Future<ShellResult> _apply({
    required PerfProfile profile,
    required PerfState state,
    required bool persistOnBoot,
    required bool lockFrequencies,
  }) {
    if (profile == PerfProfile.gaming && !state.gamingSupported) {
      return Future.value(
        const ShellResult(
          1,
          'No writable performance governor is available on this device.',
        ),
      );
    }
    if (lockFrequencies && !state.frequencyLockSupported) {
      return Future.value(
        const ShellResult(
          1,
          'Writable minimum-frequency nodes are unavailable for one or more domains.',
        ),
      );
    }
    if (persistOnBoot &&
        (profile == PerfProfile.gaming || lockFrequencies) &&
        !state.advancedBootSupported) {
      return Future.value(
        const ShellResult(
          1,
          'Update SystemPack before restoring Gaming or frequency locking at boot.',
        ),
      );
    }
    // Reject unexpected paths before generating root commands.
    for (final c in state.clusters) {
      if (!RegExp(r'^policy[0-9]+$').hasMatch(c.policy) || c.maxHardware <= 0) {
        return Future.value(const ShellResult(1, 'Invalid CPU policy data.'));
      }
    }
    final gpu = state.gpu;
    if (gpu != null &&
        ((gpu.minNode.isNotEmpty && gpu.minNode != '$kGpuDevfreq/min_freq') ||
            (gpu.governorNode.isNotEmpty &&
                gpu.governorNode != '$kGpuDevfreq/governor'))) {
      return Future.value(const ShellResult(1, 'Unexpected GPU control path.'));
    }
    final b = StringBuffer();
    b.writeln(_transactionHelpers);
    b.writeln('pmm_set_perf() {');
    b.writeln("mkdir -p '$kPerfConfigDir' || return 1");
    b.writeln('umask 077');
    b.writeln('PMM_ATTEMPTS=0');
    b.writeln('until pmm_perf_try_lock; do');
    b.writeln('  PMM_ATTEMPTS=\$((PMM_ATTEMPTS + 1))');
    b.writeln(
      "  [ \"\$PMM_ATTEMPTS\" -lt 50 ] || { echo 'Performance controls are busy; try again.'; return 1; }",
    );
    b.writeln('  sleep 0.1');
    b.writeln('done');
    b.writeln("PMM_UNDO='$kPerfConfigDir/perf-undo.tmp'");
    b.writeln(': > "\$PMM_UNDO" || return 1');
    b.writeln("touch '$kPerfOriginals' || return 1");
    final config = <String>[
      'enabled ${persistOnBoot ? 1 : 0}',
      'profile ${profile.name}',
      'lock ${lockFrequencies ? 1 : 0}',
    ];
    final kernelPairs = <String>[];
    final cpuTargets = <String, int>{};
    final releasedPairs = state.clusters
        .map(firstCpuOf)
        .whereType<int>()
        .map((cpu) => '$cpu:0')
        .join(' ');
    if (state.kernelLocksSupported && releasedPairs.isNotEmpty) {
      b.writeln(
        "pmm_write '$kKernelCpuMinNode' '$releasedPairs' '$releasedPairs' || return 1",
      );
    }
    for (final c in state.clusters) {
      final target = cappedMax(
        profile,
        cpuDomain(c, state.clusters),
        c.maxHardware,
        c.availableFreqs,
      );
      cpuTargets[c.policy] = target;
      final cpu = firstCpuOf(c);
      if (cpu != null) {
        kernelPairs.add(
          '$cpu:${profile == PerfProfile.full || profile == PerfProfile.gaming ? 0 : target}',
        );
      }
      // Lower/restore the minimum first so a lower ceiling is always accepted.
      if (lockFrequencies) {
        b.writeln(
          "pmm_remember minimum '$_cpuBase/${c.policy}/scaling_min_freq' || return 1",
        );
      }
      b.writeln(
        "pmm_restore minimum '$_cpuBase/${c.policy}/scaling_min_freq' || return 1",
      );
    }
    if (gpu != null && gpu.minNode.isNotEmpty) {
      if (lockFrequencies) {
        b.writeln("pmm_remember minimum '${gpu.minNode}' || return 1");
      }
      b.writeln("pmm_restore minimum '${gpu.minNode}' || return 1");
    }
    if (state.kernelCapsSupported && kernelPairs.isNotEmpty) {
      b.writeln(
        "pmm_write '$kKernelCpuMaxNode' '${kernelPairs.join(' ')}' '$releasedPairs' || return 1",
      );
      b.writeln(
        "pmm_write '$kKernelProfileNode' '${profile.name}' || return 1",
      );
    }
    for (final c in state.clusters) {
      final target = cpuTargets[c.policy]!;
      final base = '$_cpuBase/${c.policy}';
      b.writeln("pmm_write '$base/scaling_max_freq' '$target' || return 1");
      config.add('cpu $base $target');
      if (profile == PerfProfile.gaming && c.supportsPerformanceGovernor) {
        b.writeln("pmm_remember governor '$base/scaling_governor' || return 1");
        b.writeln(
          "pmm_write_exact '$base/scaling_governor' performance || return 1",
        );
        config.add('governor $base/scaling_governor performance');
      } else {
        b.writeln("pmm_restore governor '$base/scaling_governor' || return 1");
      }
      if (lockFrequencies) {
        b.writeln(
          "pmm_write_exact '$base/scaling_min_freq' '$target' || return 1",
        );
        config.add('minimum $base/scaling_min_freq $target');
      }
    }
    if (kernelPairs.isNotEmpty) config.add('kcpu ${kernelPairs.join(' ')}');
    if (state.kernelLocksSupported && releasedPairs.isNotEmpty) {
      final floors = lockFrequencies
          ? state.clusters
                .map((c) => '${firstCpuOf(c)}:${cpuTargets[c.policy]}')
                .join(' ')
          : releasedPairs;
      b.writeln(
        "pmm_write '$kKernelCpuMinNode' '$floors' '$releasedPairs' || return 1",
      );
      config.add('kmin $floors');
    }
    if (gpu != null && gpu.stockMax > 0) {
      final target = cappedMax(
        profile,
        PerfDomain.gpu,
        gpu.stockMax,
        gpu.availableFreqs,
      );
      b.writeln("pmm_write '$kGpuMaxNode' '$target' || return 1");
      // KGSL may aggregate this request with lower thermal limits.
      b.writeln('GACT="\$(cat $kGpuMaxNode)"');
      b.writeln(
        r'''case "$GACT" in ''|*[!0-9]*) echo 'Invalid GPU maximum readback'; return 1 ;; esac''',
      );
      b.writeln(
        '[ "\$GACT" -gt 0 ] && [ "\$GACT" -le $target ] || '
        "{ echo 'GPU did not apply the requested ceiling'; return 1; }",
      );
      config.addAll(['gpustock ${gpu.stockMax}', 'gpu $target']);
      if (profile == PerfProfile.gaming && gpu.supportsPerformanceGovernor) {
        b.writeln("pmm_remember governor '${gpu.governorNode}' || return 1");
        b.writeln(
          "pmm_write_exact '${gpu.governorNode}' performance || return 1",
        );
        config.add('governor ${gpu.governorNode} performance');
      } else if (gpu.governorNode.isNotEmpty) {
        b.writeln("pmm_restore governor '${gpu.governorNode}' || return 1");
      }
      if (lockFrequencies) {
        b.writeln("pmm_write_exact '${gpu.minNode}' '$target' || return 1");
        config.add('minimum ${gpu.minNode} $target');
      }
    }
    b.writeln("C='$kPerfConfig.tmp'");
    b.writeln(': > "\$C" || return 1');
    for (final line in config) {
      b.writeln("echo '$line' >> \"\$C\" || return 1");
    }
    b.writeln('mv "\$C" "$kPerfConfig" || return 1');
    // Remove successfully restored originals so the next session captures its
    // actual starting state instead of stale defaults from a previous session.
    b.writeln("N='$kPerfOriginals.tmp'");
    b.writeln(': > "\$N"');
    b.writeln("while read -r k n v; do");
    b.writeln("  case \"\$k\" in");
    if (profile == PerfProfile.gaming) {
      b.writeln('    governor) echo "\$k \$n \$v" >> "\$N" ;;');
    }
    if (lockFrequencies) {
      b.writeln('    minimum) echo "\$k \$n \$v" >> "\$N" ;;');
    }
    b.writeln("  *) : ;; esac; done < '$kPerfOriginals'");
    b.writeln("mv \"\$N\" '$kPerfOriginals'");
    b.writeln('echo OK_PERF');
    b.writeln('}');
    b.writeln(
      'if pmm_set_perf; then PMM_RESULT=0; else PMM_RESULT=\$?; '
      '[ "\$PMM_HAVE_LOCK" = 1 ] && pmm_rollback; fi',
    );
    b.writeln('[ "\$PMM_HAVE_LOCK" = 1 ] && rm -f "\$PMM_UNDO"');
    b.writeln('pmm_perf_unlock');
    b.writeln('(exit "\$PMM_RESULT")');
    return _shell.run(b.toString(), timeout: const Duration(seconds: 20));
  }
}

const String _transactionHelpers = r'''
# Shared application/service mutex. PID ownership prevents stealing a live
# transaction. Only dead owners or an unfinished marker older than 30s are
# recovered; the short reaper lock serializes stale-lock recovery.
pmm_process_start() {
  read -r process_pid process_stat 2>/dev/null < "/proc/$1/stat" || return 1
  # Strip the parenthesized command (which may contain spaces); starttime is
  # field 22, or the twentieth token after that command.
  set -- ${process_stat##*) }
  [ "$#" -ge 20 ] || return 1
  shift 19
  printf '%s' "$1"
}
pmm_perf_try_lock() {
  PMM_LOCK=/data/adb/picters_modules_manager/perf-apply.lock
  PMM_HAVE_LOCK=0
  PMM_PID=$$
  read -r PMM_PID _ < /proc/self/stat
  read -r PMM_BOOT_ID < /proc/sys/kernel/random/boot_id || return 1
  PMM_START=$(pmm_process_start "$PMM_PID") || return 1
  mkdir -p /data/adb/picters_modules_manager || return 1
  if mkdir "$PMM_LOCK" 2>/dev/null; then
    printf '%s %s %s %s\n' "$PMM_PID" "$(date +%s)" "$PMM_BOOT_ID" "$PMM_START" > "$PMM_LOCK/owner" || {
      rm -f "$PMM_LOCK/owner"; rmdir "$PMM_LOCK" 2>/dev/null; return 1;
    }
    PMM_HAVE_LOCK=1
    return 0
  fi
  # A crashed reaper leaves an empty directory; it may be recovered after 30s.
  if [ -d "$PMM_LOCK.reap" ]; then
    modified=$(stat -c %Y "$PMM_LOCK.reap" 2>/dev/null)
    case "$modified" in ''|*[!0-9]*) : ;; *)
      now=$(date +%s)
      [ "$((now - modified))" -ge 30 ] && rmdir "$PMM_LOCK.reap" 2>/dev/null
      ;;
    esac
  fi
  mkdir "$PMM_LOCK.reap" 2>/dev/null || return 1
  owner_pid= owner_stamp= owner_boot= owner_start=
  read -r owner_pid owner_stamp owner_boot owner_start 2>/dev/null < "$PMM_LOCK/owner"
  stale=0
  case "$owner_pid" in
    ''|*[!0-9]*)
      modified=$(stat -c %Y "$PMM_LOCK" 2>/dev/null)
      case "$modified" in ''|*[!0-9]*) : ;; *)
        now=$(date +%s); [ "$((now - modified))" -ge 30 ] && stale=1 ;;
      esac
      ;;
    *)
      if [ -n "$owner_boot" ] && [ "$owner_boot" != "$PMM_BOOT_ID" ]; then
        stale=1
      elif ! kill -0 "$owner_pid" 2>/dev/null; then
        stale=1
      elif [ -n "$owner_start" ]; then
        current_start=$(pmm_process_start "$owner_pid")
        [ "$owner_start" = "$current_start" ] || stale=1
      fi
      ;;
  esac
  if [ "$stale" = 1 ]; then
    rm -f "$PMM_LOCK/owner"
    rmdir "$PMM_LOCK" 2>/dev/null
  fi
  rmdir "$PMM_LOCK.reap" 2>/dev/null
  return 1
}
pmm_perf_unlock() {
  [ "$PMM_HAVE_LOCK" = 1 ] || return 0
  owner_pid= owner_stamp= owner_boot= owner_start=
  read -r owner_pid owner_stamp owner_boot owner_start 2>/dev/null < "$PMM_LOCK/owner"
  if [ "$owner_pid" = "$PMM_PID" ]; then
    rm -f "$PMM_LOCK/owner"
    rmdir "$PMM_LOCK" 2>/dev/null
  fi
  PMM_HAVE_LOCK=0
}

pmm_write() {
  [ -w "$1" ] || { echo "Not writable: $1"; return 1; }
  old=$(cat "$1") || return 1
  if [ -n "$3" ]; then
    # QoS reads are sparse, but writes update only named policies. Snapshot
    # every target policy so rollback explicitly releases a newly added request.
    live="$old"
    old=''
    for default_pair in $3; do
      policy_id=${default_pair%%:*}
      saved_pair=$default_pair
      for live_pair in $live; do
        case "$live_pair" in "$policy_id":*) saved_pair=$live_pair ;; esac
      done
      old="$old$saved_pair "
    done
  fi
  echo "$1 $old" >> "$PMM_UNDO" || return 1
  echo "$2" > "$1" || return 1
}
pmm_write_exact() {
  pmm_write "$1" "$2" || return 1
  [ "$(cat "$1")" = "$2" ] || { echo "Control did not apply: $1"; return 1; }
}
pmm_remember() {
  while read -r k n v; do
    [ "$k" = "$1" ] && [ "$n" = "$2" ] && return 0
  done < /data/adb/picters_modules_manager/perf-originals.conf
  v=$(cat "$2") || return 1
  [ -n "$v" ] || return 1
  echo "$1 $2 $v" >> /data/adb/picters_modules_manager/perf-originals.conf
}
pmm_restore() {
  while read -r k n v; do
    if [ "$k" = "$1" ] && [ "$n" = "$2" ]; then
      pmm_write_exact "$n" "$v" || return 1
      return 0
    fi
  done < /data/adb/picters_modules_manager/perf-originals.conf
  return 0
}
pmm_rollback() {
  [ -f "$PMM_UNDO" ] || return 0
  # First recorded value wins when a node was written more than once.
  seen=' '
  while read -r n v; do
    case "$seen" in *" $n "*) continue ;; esac
    case "$n" in */scaling_min_freq|*/min_freq) continue ;; esac
    echo "$v" > "$n" 2>/dev/null
    seen="$seen$n "
  done < "$PMM_UNDO"
  seen=' '
  while read -r n v; do
    case "$seen" in *" $n "*) continue ;; esac
    case "$n" in */scaling_min_freq|*/min_freq)
      echo "$v" > "$n" 2>/dev/null; seen="$seen$n " ;;
    esac
  done < "$PMM_UNDO"
}
''';

/// Parses [PerfRepository.scan]'s output into a [PerfState]. Pure, so the scan
/// parsing is unit-testable without a device.
PerfState parsePerfScan(String out) {
  final lines = out.split('\n');
  var section = 0; // 0 pre, 1 cpu, 2 gpu, 3 conf
  final metaByPolicy = <String, List<String>>{}; // policy -> P fields
  final freqByPolicy = <String, List<int>>{};
  final detailsByPolicy = <String, List<String>>{};
  var gpuAvail = <int>[];
  var gpuMax = 0;
  var gpuGov = <String>[];
  var gpuMin = <String>[];
  final conf = <String, String>{};
  final confCpu =
      <String, int>{}; // policyPath -> freq (unused for state, kept simple)
  var bootOk = false;
  var kernelOk = false;
  var kernelMinOk = false;
  var advancedOk = false;

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
        } else if (line.startsWith('D:')) {
          final f = line.substring(2).split('|');
          if (f.isNotEmpty) detailsByPolicy[f[0]] = f;
        } else if (line.startsWith('F:')) {
          final f = line.substring(2).split('|');
          if (f.length >= 2) freqByPolicy[f[0]] = _parseFreqList(f[1]);
        }
        break;
      case 2:
        if (line.startsWith('GGOV:')) {
          gpuGov = line.substring(5).split('|');
        } else if (line.startsWith('GMIN:')) {
          gpuMin = line.substring(5).split('|');
        } else if (line.startsWith('GAVAIL:')) {
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
        if (line == 'PERF_KERNEL_OK') kernelOk = true;
        if (line == 'PERF_KERNEL_MIN_OK') kernelMinOk = true;
        if (line == 'PERF_ADVANCED_OK') advancedOk = true;
        break;
    }
  }

  final clusters = <CpuCluster>[];
  for (final entry in metaByPolicy.entries) {
    final f = entry.value; // [policy, related, cpuinfoMax, scalingMax, gov]
    final d = detailsByPolicy[entry.key] ?? const <String>[];
    final cpus = (f.length > 1 ? f[1] : '')
        .trim()
        .split(RegExp(r'\s+'))
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    clusters.add(
      CpuCluster(
        policy: entry.key,
        cpus: cpus,
        maxHardware: f.length > 2 ? (int.tryParse(f[2].trim()) ?? 0) : 0,
        scalingMax: f.length > 3 ? (int.tryParse(f[3].trim()) ?? 0) : 0,
        availableFreqs: freqByPolicy[entry.key] ?? const [],
        governor: f.length > 4 ? f[4].trim() : '',
        scalingMin: d.length > 1 ? int.tryParse(d[1]) ?? 0 : 0,
        availableGovernors: d.length > 2
            ? d[2].split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList()
            : const [],
        governorWritable: d.length > 3 && d[3] == '1',
        minWritable: d.length > 4 && d[4] == '1',
      ),
    );
  }
  clusters.sort((a, b) => a.policy.compareTo(b.policy));

  // max_gpuclk is a writable cap, not the hardware maximum. Prefer the
  // driver's supported OPP table, so an old cap (including a saved gpustock)
  // cannot permanently reduce Full. Keep the legacy fallback without a table.
  final confGpuStock = int.tryParse(conf['gpustock'] ?? '');
  final gpu = gpuAvail.isEmpty && gpuMax == 0
      ? null
      : GpuInfo(
          availableFreqs: gpuAvail,
          currentMax: gpuMax,
          governor: gpuGov.isNotEmpty ? gpuGov[0] : '',
          governorNode: gpuGov.isNotEmpty ? '$kGpuDevfreq/governor' : '',
          availableGovernors: gpuGov.length > 1
              ? gpuGov[1]
                    .split(RegExp(r'\s+'))
                    .where((s) => s.isNotEmpty)
                    .toList()
              : const [],
          governorWritable: gpuGov.length > 2 && gpuGov[2] == '1',
          currentMin: gpuMin.isNotEmpty ? int.tryParse(gpuMin[0]) ?? 0 : 0,
          minNode: gpuMin.isNotEmpty ? '$kGpuDevfreq/min_freq' : '',
          minWritable: gpuMin.length > 1 && gpuMin[1] == '1',
          stockMax: gpuAvail.isNotEmpty
              ? gpuAvail.last
              : (confGpuStock ?? gpuMax),
        );

  final profile = PerfProfileX.fromName(conf['profile']);
  final lock = conf['lock'] == '1';
  final supportedGovernors = [
    for (final c in clusters)
      if (c.supportsPerformanceGovernor) c.governor,
    if (gpu?.supportsPerformanceGovernor ?? false) gpu!.governor,
  ];
  final targetsMatch =
      clusters.isNotEmpty &&
      clusters.every(
        (c) =>
            c.scalingMin ==
            cappedMax(
              profile ?? PerfProfile.full,
              cpuDomain(c, clusters),
              c.maxHardware,
              c.availableFreqs,
            ),
      ) &&
      (gpu == null ||
          gpu.currentMin ==
              cappedMax(
                profile ?? PerfProfile.full,
                PerfDomain.gpu,
                gpu.stockMax,
                gpu.availableFreqs,
              ));
  return PerfState(
    frequenciesLocked: lock,
    lockActive: lock && targetsMatch,
    gamingActive:
        profile == PerfProfile.gaming &&
        supportedGovernors.isNotEmpty &&
        supportedGovernors.every((g) => g == 'performance'),
    advancedBootSupported: advancedOk,
    clusters: clusters,
    gpu: gpu,
    profile: profile,
    persistOnBoot: conf['enabled'] == '1',
    bootApplySupported: bootOk,
    kernelCapsSupported: kernelOk,
    kernelLocksSupported: kernelMinOk,
  );
}
