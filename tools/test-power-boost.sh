#!/system/bin/sh
# Test only Xiaomi's normal wired power-boost command. No thermal/protection edits.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run through su.' >&2; exit 1; }
BOOST_NODE=/sys/class/xm_power/charger/smart_charge/smart_chg
BOOST_MODULE=/vendor_dlkm/lib/modules/mca_smart_charge.ko
BOOST_HASH=bc9321a44fb892f77c18739e83fbe956a06974f4a9946cf16ac01db1f2d605d7
[ "$(getprop ro.product.device)" = pudding ] || exit 1
boost_sum=$(sha256sum "$BOOST_MODULE")
[ "${boost_sum%% *}" = "$BOOST_HASH" ] || { echo 'Unsupported smart-charge ABI.' >&2; exit 1; }
[ -r "$BOOST_NODE" ] && [ -w "$BOOST_NODE" ] || { echo 'Power-boost interface unavailable.' >&2; exit 1; }
boost_name="Picters-Power-Boost-$(date +%Y%m%d-%H%M%S)-$$"
boost_dir=$(mktemp -d "/data/local/tmp/$boost_name.XXXXXX")
boost_archive="/sdcard/$boost_name.tar.gz"
boost_changed=0
boost_watchdog=
boost_finished=0
bounded() { if command -v timeout >/dev/null 2>&1; then timeout -k 1 3 "$@"; else toybox timeout -k 1 3 "$@"; fi; }
read_mask() {
  boost_mask=$(bounded cat "$BOOST_NODE") || return 1
  case "$boost_mask" in ''|*[!0-9]*|??????????*) return 1;; esac
  [ "$boost_mask" -le 32767 ] || return 1
  printf '%s\n' "$boost_mask"
}
write_command() {
  bounded sh -c 'printf "%s\n" "$2" > "$1"' sh "$BOOST_NODE" "$1"
}
boost_original=$(read_mask) || { rm -rf "$boost_dir"; echo 'Invalid smart-charge status.' >&2; exit 1; }
boost_restore=$((4 + (boost_original / 4 % 2)))
# Commands 5/4 enable/disable ONLY the power-boost feature (bit2 selector,
# bit0 enable), leaving night charging, SOC limits and other feature bits alone.
# Record the rollback before the first write. A second process also restores it
# if this collector is killed. Reboot resets vendor RAM state as a last resort.
printf '%s\n' "$boost_restore" > "$boost_dir/restore-command"
restore_boost() {
  [ "$boost_changed" = 1 ] || return 0
  write_command "$boost_restore" || return 1
  boost_actual=$(read_mask) || return 1
  [ "$((boost_actual / 4 % 2))" = "$((boost_original / 4 % 2))" ] || return 1
  boost_changed=0
}
finish_boost() {
  boost_rc=$?
  [ "$boost_finished" = 0 ] || return
  boost_finished=1
  if ! restore_boost; then
    echo 'Could not verify restoration. Reboot before further testing.' >&2
    boost_rc=1
  else
    [ -z "$boost_watchdog" ] || kill "$boost_watchdog" 2>/dev/null || true
  fi
  if tar -czf "$boost_archive" -C "$boost_dir" .; then
    chmod 0644 "$boost_archive"
    printf '\nSaved: %s\n' "$boost_archive"
    # Keep a failed rollback journal available to the watchdog.
    [ "$boost_changed" = 1 ] || rm -rf "$boost_dir"
  else
    echo "Archive failed; recording remains in $boost_dir" >&2
    boost_rc=1
  fi
  trap - EXIT
  exit "$boost_rc"
}
trap finish_boost EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
{
  date -u
  uname -a
  printf 'original_mask=%s\nrestore_command=%s\n' "$boost_original" "$boost_restore"
  getprop ro.vendor.build.fingerprint
} > "$boost_dir/device.txt"
(
  # No inherited cleanup trap: this worker must also survive the parent's exit.
  trap - EXIT INT TERM HUP
  sleep 90
  [ -f "$boost_dir/restore-command" ] || exit 0
  : > "$boost_dir/expired"
  # Allow a previously started bounded write to finish before rollback.
  sleep 4
  [ ! -f "$boost_dir/restore-command" ] || write_command "$boost_restore"
) </dev/null > "$boost_dir/watchdog.log" 2>&1 &
boost_watchdog=$!
boost_changed=1
write_command 5
boost_mask=$(read_mask)
[ "$((boost_mask / 4 % 2))" = 1 ] || { echo 'Vendor rejected power boost.' >&2; exit 1; }
printf 'Power boost accepted. Keep charger connected and display ON for this test.\n'
for boost_sample in $(seq 1 20); do
  [ ! -f "$boost_dir/expired" ] || exit 1
  {
    printf '\n=== %s ===\n' "$boost_sample"
    date -u
    boost_mask=$(read_mask)
    printf 'smart_chg_mask=%s\n' "$boost_mask"
    if [ "$((boost_mask / 4 % 2))" != 1 ]; then
      printf 'OEM cleared boost; reasserting the selected boost feature only.\n'
      [ ! -f "$boost_dir/expired" ] || exit 1
      write_command 5
      boost_mask=$(read_mask)
      [ "$((boost_mask / 4 % 2))" = 1 ] || exit 1
    fi
    bounded dumpsys power 2>/dev/null | grep -E 'mWakefulness=|mInteractive=|Display Power:' || true
    for boost_path in /sys/class/power_supply/battery/current_now /sys/class/power_supply/battery/voltage_now /sys/class/power_supply/battery/temp /sys/class/power_supply/battery/status /sys/class/power_supply/usb/voltage_now /sys/class/power_supply/usb/current_now /sys/class/xm_power/charger/charge_interface/ichg_limit /sys/class/xm_power/charger/charge_interface/iin_limit /sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit /sys/class/xm_power/cp_master/vbus /sys/class/xm_power/cp_master/ibus; do
      [ -r "$boost_path" ] || continue
      printf '%s=' "$boost_path"
      bounded head -c 4096 "$boost_path"
      printf '\n'
    done
  } >> "$boost_dir/samples.txt" 2>&1
  sleep 2
done
restore_boost
printf 'Restored original power-boost state.\n' > "$boost_dir/restoration.txt"
