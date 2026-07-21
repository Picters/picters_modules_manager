/// CPU/GPU performance-cap model and the (pure, unit-tested) frequency maths.
///
/// Safety by construction: a profile only ever caps a domain's max frequency
/// *down* to a step that already exists in its `scaling_available_frequencies`
/// / `gpu_available_frequencies` table, and never above the stock maximum. No
/// undervolting, no OPP-table edits, no above-stock overclock — every value
/// written is a hardware-validated operating point, so it can't push the SoC
/// out of its safe range.
library;

/// A frequency-cap preset. `full` restores the stock maximum; the others cap
/// down for less heat and better battery.
enum PerfProfile { cool, balanced, full }

extension PerfProfileX on PerfProfile {
  String get label => switch (this) {
        PerfProfile.cool => 'Cool',
        PerfProfile.balanced => 'Balanced',
        PerfProfile.full => 'Full',
      };

  String get blurb => switch (this) {
        PerfProfile.cool => 'Coolest and longest battery — caps clocks hard.',
        PerfProfile.balanced => 'A middle ground — trims the top clocks.',
        PerfProfile.full => 'Stock clocks — full performance.',
      };

  /// Fraction of each domain's stock max this profile targets before snapping
  /// to a real OPP step. Full is exactly the stock max.
  double get fraction => switch (this) {
        PerfProfile.cool => 0.60,
        PerfProfile.balanced => 0.80,
        PerfProfile.full => 1.0,
      };

  static PerfProfile? fromName(String? name) {
    for (final p in PerfProfile.values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// The highest frequency in [available] that is `<= target`, never below the
/// lowest available step. [available] must be non-empty. The result is always a
/// real entry from the table, so it's safe to write to a scaling node.
int snapDownToAvailable(List<int> available, int target) {
  final sorted = [...available]..sort();
  var pick = sorted.first;
  for (final f in sorted) {
    if (f <= target) {
      pick = f;
    } else {
      break;
    }
  }
  return pick;
}

/// The capped max frequency for a domain whose stock ceiling is [stockMax] and
/// whose OPP table is [available], under [profile]. Full returns exactly
/// [stockMax]; the others snap `fraction * stockMax` down to a real step. Never
/// exceeds [stockMax].
int cappedMax(PerfProfile profile, int stockMax, List<int> available) {
  if (profile == PerfProfile.full || available.isEmpty) return stockMax;
  final target = (stockMax * profile.fraction).round();
  final snapped = snapDownToAvailable(available, target);
  return snapped > stockMax ? stockMax : snapped;
}

/// One CPU frequency domain (a cpufreq policy = a cluster of cores).
class CpuCluster {
  const CpuCluster({
    required this.policy,
    required this.cpus,
    required this.maxHardware,
    required this.scalingMax,
    required this.availableFreqs,
    required this.governor,
  });

  /// Policy dir name, e.g. "policy0".
  final String policy;

  /// The CPUs this policy governs, e.g. [0,1,2,3,4,5].
  final List<int> cpus;

  /// cpuinfo_max_freq — the hardware/stock ceiling (kHz). Stable reference for
  /// the Full/restore target.
  final int maxHardware;

  /// Current scaling_max_freq (kHz).
  final int scalingMax;

  /// scaling_available_frequencies (kHz), ascending.
  final List<int> availableFreqs;

  /// Current scaling_governor.
  final String governor;

  int get coreCount => cpus.length;
}

/// The GPU (Adreno / kgsl) frequency domain.
class GpuInfo {
  const GpuInfo({
    required this.availableFreqs,
    required this.currentMax,
    required this.stockMax,
  });

  /// gpu_available_frequencies (Hz), ascending.
  final List<int> availableFreqs;

  /// Current max_gpuclk (Hz).
  final int currentMax;

  /// The stock max_gpuclk captured before any cap was applied (Hz) — the
  /// Full/restore target, so we never raise the GPU above its stock ceiling.
  final int stockMax;
}

/// A full snapshot of the CPU/GPU cap state, plus the persisted profile and the
/// boot-persist flag.
class PerfState {
  const PerfState({
    required this.clusters,
    required this.gpu,
    required this.profile,
    required this.persistOnBoot,
  });

  final List<CpuCluster> clusters;
  final GpuInfo? gpu;

  /// The profile last applied (from the config), or null when the live caps
  /// don't match any preset (custom / untouched).
  final PerfProfile? profile;

  /// Whether the module re-applies these caps at boot.
  final bool persistOnBoot;

  bool get isEmpty => clusters.isEmpty;

  static const empty = PerfState(
    clusters: [],
    gpu: null,
    profile: null,
    persistOnBoot: false,
  );
}

/// Human label for a CPU domain given the whole set (the highest-clocked
/// smaller cluster reads as "Prime", the rest as "Performance"/"Efficiency").
String clusterLabel(CpuCluster c, List<CpuCluster> all) {
  if (all.length <= 1) return 'CPU';
  final maxOfAll = all.map((e) => e.maxHardware).reduce((a, b) => a > b ? a : b);
  if (c.maxHardware == maxOfAll) return 'Prime cores';
  final minOfAll = all.map((e) => e.maxHardware).reduce((a, b) => a < b ? a : b);
  if (c.maxHardware == minOfAll && all.length >= 3) return 'Efficiency cores';
  return 'Performance cores';
}

/// "2.11 GHz" from a kHz cpufreq value.
String formatCpuFreq(int khz) {
  final ghz = khz / 1000000.0;
  return '${ghz.toStringAsFixed(2)} GHz';
}

/// "539 MHz" from a Hz GPU value.
String formatGpuFreq(int hz) {
  final mhz = (hz / 1000000.0).round();
  return '$mhz MHz';
}
