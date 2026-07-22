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
enum PerfProfile { eco, balanced, full }

extension PerfProfileX on PerfProfile {
  String get label => switch (this) {
        PerfProfile.eco => 'Eco',
        PerfProfile.balanced => 'Balanced',
        PerfProfile.full => 'Full',
      };

  String get blurb => switch (this) {
        PerfProfile.eco =>
          'Coolest and longest battery — hard caps, prime cores hit hardest.',
        PerfProfile.balanced => 'Cooler but still snappy — trims the top clocks.',
        PerfProfile.full => 'Stock clocks — full performance.',
      };

  static PerfProfile? fromName(String? name) {
    for (final p in PerfProfile.values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// A frequency domain. Caps are asymmetric — the prime cores are the main heat
/// source, so they're hit harder than the perf cores.
enum PerfDomain { primeCpu, perfCpu, gpu }

/// Fraction of a domain's stock max a profile targets before snapping to a real
/// OPP step. Full is stock; prime is capped the hardest.
double profileFraction(PerfProfile profile, PerfDomain domain) =>
    switch (profile) {
      PerfProfile.full => 1.0,
      PerfProfile.eco => switch (domain) {
          PerfDomain.primeCpu => 0.46,
          PerfDomain.perfCpu => 0.53,
          PerfDomain.gpu => 0.47,
        },
      PerfProfile.balanced => switch (domain) {
          PerfDomain.primeCpu => 0.68,
          PerfDomain.perfCpu => 0.69,
          PerfDomain.gpu => 0.72,
        },
    };

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

/// The capped max frequency for [domain] (stock ceiling [stockMax], OPP table
/// [available]) under [profile]. Full returns exactly [stockMax]; the others
/// snap `profileFraction * stockMax` down to a real step. Never exceeds
/// [stockMax].
int cappedMax(
  PerfProfile profile,
  PerfDomain domain,
  int stockMax,
  List<int> available,
) {
  if (profile == PerfProfile.full || available.isEmpty) return stockMax;
  final target = (stockMax * profileFraction(profile, domain)).round();
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
    required this.bootApplySupported,
  });

  final List<CpuCluster> clusters;
  final GpuInfo? gpu;

  /// The profile last applied (from the config), or null when the live caps
  /// don't match any preset (custom / untouched).
  final PerfProfile? profile;

  /// Whether the module re-applies these caps at boot.
  final bool persistOnBoot;

  /// Whether the installed module's boot service carries the perf re-apply loop.
  /// The vendor perf HAL rewrites scaling_max_freq, so without that loop a cap
  /// can't be enforced — the UI blocks the controls and asks for a module update.
  final bool bootApplySupported;

  bool get isEmpty => clusters.isEmpty;

  static const empty = PerfState(
    clusters: [],
    gpu: null,
    profile: null,
    persistOnBoot: false,
    bootApplySupported: false,
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

/// Which cap domain a CPU cluster belongs to — the highest-clocked cluster is
/// the prime (hit hardest); the rest are perf cores.
PerfDomain cpuDomain(CpuCluster c, List<CpuCluster> all) {
  if (all.isEmpty) return PerfDomain.perfCpu;
  final maxOfAll = all.map((e) => e.maxHardware).reduce((a, b) => a > b ? a : b);
  return c.maxHardware == maxOfAll ? PerfDomain.primeCpu : PerfDomain.perfCpu;
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
