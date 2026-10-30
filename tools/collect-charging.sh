#!/system/bin/sh
# Read-only charger capability capture. No sysfs writes or service changes.
# Run while a charger is connected: su -c 'sh /sdcard/collect-charging.sh'
set -u
umask 077
if [ "$(id -u)" != 0 ]; then
  echo "Run: su -c 'sh /sdcard/collect-charging.sh'" >&2
  exit 1
fi
charging_name="Picters-Charging-$(date +%Y%m%d-%H%M%S)-$$"
charging_dir=$(mktemp -d "/data/local/tmp/${charging_name}.XXXXXX") || exit 1
charging_archive="/sdcard/${charging_name}.tar.gz"
trap 'rm -rf "$charging_dir"' EXIT
mkdir -p "$charging_dir/files"

bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 3 "$@"
  elif command -v toybox >/dev/null 2>&1; then
    toybox timeout -k 1 3 "$@"
  else
    echo 'Skipped: timeout unavailable'
  fi
}

{
  date -u
  uname -a
  for charging_prop in ro.product.device ro.product.model ro.soc.model ro.board.platform ro.build.version.sdk ro.vendor.build.version.sdk ro.vendor.build.fingerprint; do
    printf '%s=' "$charging_prop"
    getprop "$charging_prop"
  done
} > "$charging_dir/device.txt" 2>&1

capture_nodes() {
  for charging_root in /sys/class/power_supply/* /sys/class/qcom-battery /sys/class/xiaomi-battery /sys/class/mi_charger/*; do
    [ -d "$charging_root" ] || continue
    printf '\n=== %s ===\n' "$charging_root"
    readlink -f "$charging_root"
    # Inventory exposes permissions and interface names, not device serials.
    ls -la "$charging_root/"
    for charging_node in "$charging_root"/*; do
      [ -f "$charging_node" ] && [ -r "$charging_node" ] || continue
      charging_field=${charging_node##*/}
      case "$charging_field" in
        type|status|health|present|online|capacity|capacity_level|technology|scope|temp|temp_now|connector_temp|usb_temp|voltage_now|voltage_max|voltage_max_design|voltage_min_design|current_now|current_avg|current_max|power_now|power_avg|power_max|input_power_limit|input_current_limit|input_voltage_limit|constant_charge_current|constant_charge_current_max|constant_charge_voltage|constant_charge_voltage_max|charge_control_limit|charge_control_limit_max|charge_control_start_threshold|charge_control_end_threshold|charge_behaviour|charge_types|charge_type|usb_type|real_type|pd_active|pd_current_max|pd_voltage_max|pd_voltage_min|pps_power_max|apdo_max|charging_enabled|battery_charging_enabled|charge_enabled|charge_disable|charging_disabled|input_suspend|bypass|bypass_charging|bypass_mode|charge_bypass|fastcharge_mode|fast_charge_current|mtbf_current|thermal_input_current_limit|thermal_mitigation|thermal_level|charge_thermal_level|fcc_votable|icl_votable)
          printf '\n%s=' "$charging_node"
          bounded head -c 8192 "$charging_node"
          printf '\n'
          ;;
      esac
    done
  done
}
printf 'Collecting charger interfaces; keep the charger connected...\n'
capture_nodes > "$charging_dir/interfaces.txt" 2>&1

{
  for charging_sample in 1 2 3 4 5; do
    printf '\n=== Sample %s ===\n' "$charging_sample"
    date -u
    for charging_supply in battery usb main bms cp_master cp_slave; do
      for charging_field in status online temp voltage_now current_now power_now input_current_limit input_power_limit current_max voltage_max; do
        charging_node="/sys/class/power_supply/$charging_supply/$charging_field"
        [ -r "$charging_node" ] || continue
        printf '%s=' "$charging_node"
        bounded head -c 512 "$charging_node"
        printf '\n'
      done
    done
    [ "$charging_sample" = 5 ] || sleep 1
  done
} > "$charging_dir/samples.txt" 2>&1

{
  for charging_port in /sys/class/typec/*; do
    [ -d "$charging_port" ] || continue
    printf '\n=== %s ===\n' "$charging_port"
    for charging_field in power_role data_role power_operation_mode preferred_role; do
      [ -r "$charging_port/$charging_field" ] || continue
      printf '%s=' "$charging_field"
      bounded head -c 512 "$charging_port/$charging_field"
      printf '\n'
    done
  done
  bounded dumpsys battery
  getprop | grep -iE '^\[init\.svc\.[^]]*(thermal|charg|battery)' || true
} > "$charging_dir/runtime.txt" 2>&1

# MCA-specific attributes identified in the captured Xiaomi init configuration.
# Restrict reads to explicit control/telemetry names, excluding serials and
# firmware/debug/shipmode/register nodes.
{
  for charging_group in /sys/class/xm_power/charger/charge_interface /sys/class/xm_power/charger/quick_charge /sys/class/xm_power/charger/charger_thermal /sys/class/xm_power/charger/strategy_pbb /sys/class/xm_power/typec /sys/class/xm_power/cp_master /sys/class/xm_power/cp_slave; do
    [ -d "$charging_group" ] || continue
    printf '\n=== %s ===\n' "$charging_group"
    readlink -f "$charging_group"
    ls -la "$charging_group/"
    for charging_field in charge_enable input_suspend iin_limit ibat_limit ichg_limit fcc_limit power_limit input_power_limit current_ration wired_ctrl_limit wired_thermal_limit pbb_normal_info apdo_max pd_active pd_verifed real_type quick_charge_type vbus ibus vbat ibat input_voltage input_current output_voltage output_current charge_type charge_mode charging_state; do
      charging_node="$charging_group/$charging_field"
      [ -r "$charging_node" ] && [ -f "$charging_node" ] || continue
      printf '\n%s=' "$charging_node"
      bounded head -c 8192 "$charging_node"
      printf '\n'
    done
  done
} > "$charging_dir/mca-interfaces.txt" 2>&1

# Retain the actual vendor charger implementation for offline unit/control
# analysis; these are system binaries, not user data. Copy at most 16 MiB/file.
{
  for charging_modules in /vendor_dlkm/lib/modules /vendor/lib/modules /odm_dlkm/lib/modules; do
    [ -d "$charging_modules" ] || continue
    find "$charging_modules" -maxdepth 2 -type f -name '*mca*.ko' 2>/dev/null
  done
  [ ! -f /vendor/bin/hw/vendor.xiaomi.hardware.micharge-service ] || printf '%s\n' /vendor/bin/hw/vendor.xiaomi.hardware.micharge-service
} | sort -u | while IFS= read -r charging_binary; do
  charging_size=$(stat -c %s "$charging_binary" 2>/dev/null) || continue
  [ "$charging_size" -gt 0 ] && [ "$charging_size" -le 16777216 ] || continue
  charging_target="$charging_dir/files$charging_binary"
  mkdir -p "$(dirname "$charging_target")"
  bounded cp "$charging_binary" "$charging_target" || rm -f "$charging_target"
done

# Capture init service names/restart declarations for later activation research.
for charging_rc in /vendor/etc/init/*thermal*.rc /odm/etc/init/*thermal*.rc /vendor/etc/init/*charg*.rc; do
  [ -f "$charging_rc" ] || continue
  charging_target="$charging_dir/files$charging_rc"
  mkdir -p "$(dirname "$charging_target")"
  bounded head -c 131072 "$charging_rc" > "$charging_target"
done
cat > "$charging_dir/README.txt" <<'NOTE'
Read-only capture. No charger limits, thermal profiles or services were changed.
Snapshot while plugged in; supply status determines current direction.
Power_supply units normally use microvolts/microamps/microwatts and tenths C.
Battery-terminal watts do not establish adapter input watts or bypass support.
Writable file permissions do not establish that a control works on this device.
No serial-number attributes, user files, logs or accounts are collected.
NOTE
if tar -czf "$charging_archive" -C "$charging_dir" .; then
  chmod 0644 "$charging_archive"
  printf '\nSaved: %s\n' "$charging_archive"
else
  rm -f "$charging_archive"
  echo 'Could not create capture archive.' >&2
  exit 1
fi
