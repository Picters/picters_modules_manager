# =============================================================================
# Picters Modules Manager — CPU/GPU performance caps: boot applier
# =============================================================================
# NOTE: this is now generated automatically by the CI — see
# Kokuban_Kernel_CI_Center/ci_core_rs/src/build.rs `build_boot_service()`, which
# emits it into the module's service.sh. This file is kept only as a readable
# reference / for a hand-built module. The live version re-applies on a LOOP
# (every 10s), because the vendor perf HAL (perfd) OWNS scaling_max_freq and
# rewrites it on load/thermal events — a one-shot cap does not hold on this SoC.
#
# It reads the config the app writes and re-applies the caps at boot (late_start;
# NOT post-fs-data — cpufreq nodes aren't ready that early).
#
# SAFETY: it only ever writes frequencies the app already validated against the
# hardware's OPP table, and only if `enabled 1`. If anything misbehaves (e.g. a
# non-booting device), removing the module means this never runs and the device
# comes up at stock clocks. The config lives outside /data/adb/modules so it
# survives a module update.
#
# Config file the app writes (example):
#   enabled 1
#   profile cool
#   gpustock 902000000
#   cpu /sys/devices/system/cpu/cpufreq/policy0 2112000
#   cpu /sys/devices/system/cpu/cpufreq/policy6 2668800
#   gpu 539000000
# =============================================================================

PMM_PERF_CONF=/data/adb/picters_modules_manager/perf.conf

pmm_apply_perf() {
  [ -f "$PMM_PERF_CONF" ] || return 0

  # Gate on the enabled flag.
  pmm_enabled=0
  while read -r k a _; do
    [ "$k" = "enabled" ] && pmm_enabled="$a"
  done < "$PMM_PERF_CONF"
  [ "$pmm_enabled" = "1" ] || return 0

  while read -r k a b; do
    case "$k" in
      cpu)
        [ -n "$b" ] && [ -w "$a/scaling_max_freq" ] && \
          echo "$b" > "$a/scaling_max_freq" 2>/dev/null
        ;;
      gpu)
        [ -n "$a" ] && [ -w /sys/class/kgsl/kgsl-3d0/max_gpuclk ] && \
          echo "$a" > /sys/class/kgsl/kgsl-3d0/max_gpuclk 2>/dev/null
        ;;
    esac
  done < "$PMM_PERF_CONF"
}

# Apply once the system has settled, then again a little later so the vendor
# perf HAL (perfd/mpctl), which can rewrite scaling_max_freq during early boot,
# doesn't clobber the cap. Runs in the background so it never blocks boot.
(
  sleep 20
  pmm_apply_perf
  sleep 40
  pmm_apply_perf
) &
