#!/system/bin/sh
# Read-only capture of the pudding charging policy and adapter path.
set -eu
umask 077
[ "$(id -u)" = 0 ] || { echo 'Run through su.' >&2; exit 1; }
name="Picters-Charging-Path-$(date +%Y%m%d-%H%M%S)-$$"
work=$(mktemp -d "/data/local/tmp/$name.XXXXXX")
archive="/sdcard/$name.tar.gz"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/files"
bounded() { if command -v timeout >/dev/null 2>&1; then timeout -k 1 3 "$@"; else toybox timeout -k 1 3 "$@"; fi; }
copy_file() {
  source=$1
  [ -f "$source" ] && [ -r "$source" ] || return 0
  size=$(stat -c %s "$source" 2>/dev/null) || return 0
  [ "$size" -ge 0 ] && [ "$size" -le 4194304 ] || return 0
  mkdir -p "$work/files${source%/*}"
  bounded head -c 4194304 "$source" > "$work/files$source" || true
}
{
  date -u
  uname -a
  for prop in ro.product.device ro.product.model ro.build.version.sdk ro.vendor.build.version.sdk ro.vendor.build.fingerprint; do
    printf '%s=' "$prop"; getprop "$prop"
  done
  bounded dumpsys package com.picters.modulesmanager | grep -E 'versionName=|versionCode=|lastUpdateTime=' || true
  getprop | grep -E '^\[init.svc.[^]]*(charg|thermal|battery)' || true
} > "$work/device.txt" 2>&1
for file in /data/adb/picters_modules_manager/charging/policy /data/adb/picters_modules_manager/charging/service.log /data/adb/picters_modules_manager/thermal/session/target /data/adb/picters_modules_manager/thermal/session/persist /data/adb/modules/picters-modules-pack/module.prop /vendor/etc/thermald-devices.conf /vendor/etc/thermal-*.conf /odm/etc/thermal-*.conf /data/vendor/thermal/config/thermal-*.conf /vendor/etc/init/*charg*.rc /vendor/etc/init/*thermal*.rc; do
  copy_file "$file"
done
for module in mca_smart_charge mca_charger_thermal mca_strategy_buckchg mca_strategy_quickchg mca_qcom_subpmic_proxy mca_voter mi_thermal_interface; do
  file="/vendor_dlkm/lib/modules/$module.ko"
  [ -f "$file" ] || file="/vendor/lib/modules/$module.ko"
  if [ -f "$file" ]; then
    sha256sum "$file" >> "$work/module-hashes.txt"
    copy_file "$file"
  fi
done
# Copy bounded hardware policy properties, not the whole device tree or serials.
for tree in /sys/firmware/devicetree/base/soc/*mca* /sys/firmware/devicetree/base/soc/*thermal* /sys/firmware/devicetree/base/*charger*; do
  [ -d "$tree" ] || continue
  find "$tree" -maxdepth 5 -type f 2>/dev/null | while IFS= read -r file; do
    case "${file##*/}" in
      compatible|name|status|*thermal*|*screen*|*charg*|*volt*|*curr*|*ilim*|*fcc*|*pps*|*pdo*|*max*|*limit*|*jeita*) copy_file "$file";;
    esac
  done
done
{
  for root in /sys/class/xm_power/charger/* /sys/class/xm_power/typec /sys/class/xm_power/fuelgauge/strategy_fg /sys/class/thermal/thermal_message; do
    [ -d "$root" ] || continue
    printf '\n=== %s ===\n' "$root"
    ls -la "$root/"
  done
  for cooling in /sys/class/thermal/cooling_device*; do
    [ -d "$cooling" ] || continue
    type=$(cat "$cooling/type" 2>/dev/null || true)
    case "$type" in *batt*|*charg*)
      printf '\n%s type=%s\n' "$cooling" "$type"
      for field in cur_state max_state; do
        printf '%s=' "$field"; bounded cat "$cooling/$field" || true
      done;;
    esac
  done
} > "$work/inventory.txt" 2>&1
read_value() {
  [ -r "$1" ] && [ -f "$1" ] || return 0
  printf '%s=' "$1"
  bounded head -c 4096 "$1" || true
  printf '\n'
}
printf 'RECORDING NOW. Leave charger and profile unchanged.\nKeep screen ON for 40 seconds, OFF for 40 seconds, then ON until Saved.\nRecording is limited to about 100 seconds plus the last snapshot.\n'
record_start=$(date +%s)
for sample in $(seq 1 50); do
  [ "$(( $(date +%s) - record_start ))" -lt 100 ] || break
  {
    printf '\n=== Sample %s ===\n' "$sample"
    date -u
    bounded dumpsys power 2>/dev/null | grep -E 'mWakefulness=|mInteractive=|Display Power:' || true
    for supply in battery usb main bms; do
      for field in status health capacity temp voltage_now current_now current_max voltage_max charge_type usb_type real_type; do
        read_value "/sys/class/power_supply/$supply/$field"
      done
    done
    for field in power_target status effective_limits; do read_value "/sys/kernel/picters_charging/$field"; done
    for root in /sys/class/xm_power/charger/charge_interface /sys/class/xm_power/charger/quick_charge /sys/class/xm_power/charger/charger_thermal /sys/class/xm_power/charger/smart_charge /sys/class/xm_power/charger/charger_common /sys/class/xm_power/charger/strategy_pbb /sys/class/xm_power/typec /sys/class/xm_power/cp_master /sys/class/xm_power/cp_slave /sys/class/thermal/thermal_message; do
      for field in ichg_limit iin_limit input_suspend charge_enable mode_enable quick_charge_type power_max current_limit cp_path_enable wired_ctrl_limit wired_chg_curr wired_chg_curr2 smart_chg smart_sic_mode pbb_normal_info real_type apdo_max pps_ptf screen_state screen_on board_sensor_temp sconfig temp_state vbus ibus tdie batt_temp; do
        read_value "$root/$field"
      done
    done
  } >> "$work/samples.txt" 2>&1
  [ "$(( $(date +%s) - record_start ))" -lt 100 ] || break
  sleep 2
done
bounded logcat -d -t 8000 -v threadtime 2>/dev/null | grep -iE 'micharge|mca_|mi_thermald|wired_ctrl|volt_thermal|screenState|PMM_' | tail -c 524288 > "$work/policy-logcat.txt" || true
bounded dmesg 2>/dev/null | grep -iE 'mca_|mi_thermal|volt_thermal|charger|charge.pump' | tail -c 524288 > "$work/policy-dmesg.txt" || true
cat > "$work/README.txt" <<'NOTE'
Read-only. No charger, temperature, protection, display, profile or service settings changed.
Hardware policy files, whitelisted device-tree properties, charging telemetry,
filtered service logs and package version are included. No user files/accounts collected.
Screen state is recorded alongside sequential (not atomic) electrical samples.
Battery power and charge-pump/native USB measurements have different scopes/units.
Do not infer adapter input power or charger capabilities from battery watts alone.
NOTE
if tar -czf "$archive" -C "$work" .; then
  chmod 0644 "$archive"
  printf '\nSaved: %s\n' "$archive"
else
  rm -f "$archive"
  exit 1
fi
