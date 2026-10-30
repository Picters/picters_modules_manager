#!/system/bin/sh
# Read-only Gaming diagnostics. Usage: su -c 'sh /sdcard/inspect-gaming-device.sh'
set -u
umask 077

if [ "$(id -u)" != 0 ]; then
  echo "Run as root: su -c 'sh /sdcard/inspect-gaming-device.sh'" >&2
  exit 1
fi

report_stamp=$(date +%Y%m%d-%H%M%S)
report_name="Picters-Gaming-${report_stamp}-$$"
report_dir=$(mktemp -d "/data/local/tmp/${report_name}.XXXXXX") || exit 1
report_archive="/sdcard/${report_name}.tar.gz"

# Bound vendor service calls; skip them when no timeout implementation exists.
run_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 2 15 "$@"
  elif command -v toybox >/dev/null 2>&1; then
    toybox timeout -k 2 15 "$@"
  else
    echo "Skipped (timeout unavailable): $*"
  fi
}

read_nodes() {
  report_base=$1
  shift
  printf '\n[%s]\n' "$report_base"
  for report_field in "$@"; do
    report_node="$report_base/$report_field"
    [ -r "$report_node" ] || continue
    printf '%s: ' "$report_field"
    cat "$report_node" 2>&1 || true
    printf '\n'
  done
}

printf 'Collecting Gaming diagnostics...\n'
{
  date -u
  uname -a
  for report_prop in ro.product.device ro.product.model ro.soc.model ro.soc.manufacturer ro.board.platform ro.build.version.release ro.build.version.sdk ro.build.version.incremental ro.vendor.build.fingerprint ro.vendor.build.version.sdk ro.vendor.build.security_patch ro.bootimage.build.fingerprint; do
    printf '%s=' "$report_prop"
    getprop "$report_prop"
  done
} > "$report_dir/device.txt" 2>&1

{
  read_nodes /sys/devices/system/cpu online offline present possible
  for report_policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$report_policy" ] || continue
    read_nodes "$report_policy" related_cpus affected_cpus scaling_driver cpuinfo_min_freq cpuinfo_max_freq cpuinfo_cur_freq scaling_available_frequencies scaling_available_governors scaling_governor scaling_min_freq scaling_max_freq scaling_cur_freq bios_limit
    read_nodes "$report_policy/stats" time_in_state total_trans
    read_nodes "$report_policy/walt" hispeed_freq hispeed_load target_loads up_rate_limit_us down_rate_limit_us
    read_nodes "$report_policy/schedutil" up_rate_limit_us down_rate_limit_us rate_limit_us
  done
} > "$report_dir/cpu.txt" 2>&1

{
  read_nodes /sys/class/kgsl/kgsl-3d0 gpu_model gpu_available_frequencies max_gpuclk min_gpuclk gpuclk gpubusy thermal_pwrlevel default_pwrlevel num_pwrlevels min_pwrlevel max_pwrlevel bus_split force_clk_on force_bus_on force_rail_on force_no_nap idle_timer throttling stats
  read_nodes /sys/class/kgsl/kgsl-3d0/devfreq name available_governors governor available_frequencies min_freq max_freq cur_freq target_freq trans_stat polling_interval
} > "$report_dir/gpu.txt" 2>&1

{
  for report_devfreq in /sys/class/devfreq/*; do
    [ -d "$report_devfreq" ] || continue
    read_nodes "$report_devfreq" name available_governors governor available_frequencies min_freq max_freq cur_freq target_freq
  done
} > "$report_dir/devfreq.txt" 2>&1

{
  read_nodes /sys/kernel/picters_perf capabilities available cpu_max_freq cpu_min_freq profile
  read_nodes /data/adb/picters_modules_manager perf.conf
  for report_module in /data/adb/modules/*; do
    [ -f "$report_module/module.prop" ] || continue
    case "$report_module" in
      *picters*) read_nodes "$report_module" module.prop ;;
    esac
  done
} > "$report_dir/picters.txt" 2>&1

{
  for report_thermal in /sys/class/thermal/thermal_zone*; do
    [ -d "$report_thermal" ] || continue
    read_nodes "$report_thermal" type temp policy mode
    for report_trip in "$report_thermal"/trip_point_*_temp; do
      [ -r "$report_trip" ] || continue
      printf '%s: ' "${report_trip##*/}"
      cat "$report_trip"
    done
  done
  for report_cooling in /sys/class/thermal/cooling_device*; do
    [ -d "$report_cooling" ] || continue
    read_nodes "$report_cooling" type cur_state max_state
  done
} > "$report_dir/thermal.txt" 2>&1

{
  for report_supply in /sys/class/power_supply/*; do
    [ -d "$report_supply" ] || continue
    read_nodes "$report_supply" type status capacity temp voltage_now current_now power_now current_max voltage_max input_current_limit charge_control_limit charge_control_limit_max
  done
} > "$report_dir/power-supply.txt" 2>&1

{
  run_bounded service list | grep -iE 'power|game|perf|thermal' || true
  run_bounded dumpsys -l | grep -iE 'power|game|perf|thermal' || true
  printf '\n=== Vendor performance configuration files ===\n'
  for report_config in /vendor/etc/powerhint* /vendor/etc/*perf* /vendor/etc/*thermal* /vendor/etc/perf/* /odm/etc/*thermal*; do
    [ -e "$report_config" ] || continue
    ls -ld "$report_config"
  done
} > "$report_dir/services.txt" 2>&1
run_bounded dumpsys power > "$report_dir/power-hal.txt" 2>&1 || true
run_bounded dumpsys thermalservice > "$report_dir/thermal-service.txt" 2>&1 || true
run_bounded dumpsys game > "$report_dir/game-service.txt" 2>&1 || true
run_bounded cmd game help > "$report_dir/game-commands.txt" 2>&1 || true

{
  for report_sample in 1 2 3 4 5; do
    printf '\n=== Sample %s ===\n' "$report_sample"
    date -u
    for report_policy in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "$report_policy" ] || continue
      read_nodes "$report_policy" scaling_governor scaling_cur_freq scaling_min_freq scaling_max_freq
    done
    read_nodes /sys/class/kgsl/kgsl-3d0 gpuclk gpubusy max_gpuclk thermal_pwrlevel
    read_nodes /sys/class/kgsl/kgsl-3d0/devfreq governor cur_freq min_freq max_freq
    [ "$report_sample" = 5 ] || sleep 1
  done
} > "$report_dir/samples.txt" 2>&1

cat > "$report_dir/README.txt" <<'NOTE'
Picters Gaming diagnostics
Read-only collection; no governor, frequency, thermal or battery settings changed.
Missing nodes, unavailable commands and permission errors are kept in each report.
Five samples at roughly one-second intervals are snapshots, not an FPS benchmark.
For comparison collect one archive in Full, then one in Gaming under the same game
and settings. Record the active game and whether the device was charging.
NOTE

if tar -czf "$report_archive" -C "$report_dir" .; then
  rm -rf "$report_dir"
  printf '\nSaved: %s\n' "$report_archive"
else
  rm -f "$report_archive"
  report_archive="/sdcard/${report_name}.tar"
  if tar -cf "$report_archive" -C "$report_dir" .; then
    rm -rf "$report_dir"
    printf '\nSaved: %s\n' "$report_archive"
  else
    rm -f "$report_archive"
    printf '\nArchive failed. Reports retained in: %s\n' "$report_dir" >&2
    exit 1
  fi
fi
