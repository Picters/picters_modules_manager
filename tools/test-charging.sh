#!/system/bin/sh
# Picters Xiaomi 17 charging investigation. Default mode only reads nodes.
# observe: change the Scene charging limit, then restore it in Scene.
# probe-buck: short, independent 500 mA input-current vote, released on exit.
set -u
umask 077
[ "$(id -u)" = 0 ] || { echo 'Run this script through su.' >&2; exit 1; }
mode=${1:-observe}
seconds=${2:-120}
case "$mode" in observe|probe-buck) ;; *) echo 'Usage: sh test-charging.sh [observe [30..300]|probe-buck]' >&2; exit 1;; esac
case "$seconds" in ''|*[!0-9]*|????*) echo 'Invalid duration.' >&2; exit 1;; esac
[ "$seconds" -ge 30 ] && [ "$seconds" -le 300 ] || { echo 'Duration must be 30..300 seconds.' >&2; exit 1; }
name="Picters-Charging-Test-$(date +%Y%m%d-%H%M%S)-$$"
work=$(mktemp -d "/data/local/tmp/$name.XXXXXX") || exit 1
archive="/sdcard/$name.tar.gz"
node=/sys/class/xm_power/charger/charge_interface/iin_limit
client="PMMP_$$"
vote_active=0
watchdog_pid=
finished=0

bounded() {
  if command -v timeout >/dev/null 2>&1; then timeout -k 1 3 "$@"
  else toybox timeout -k 1 3 "$@"; fi
}
write_vote() {
  printf 'client=%s request_mA=%s\n' "$client" "$1" >> "$work/writes.txt"
  bounded sh -c 'printf "%s\n" "$2" > "$1"' sh "$node" "$client buck $1" >> "$work/writes.txt" 2>&1
}
release_vote() {
  [ "$vote_active" = 1 ] || return 0
  if write_vote 0; then
    vote_active=0
    echo 'Own buck vote released.' >> "$work/writes.txt"
  else
    echo 'RESET FAILED: unplug the charger and reboot before further testing.' | tee -a "$work/writes.txt" >&2
    return 1
  fi
}
finish() {
  finish_status=$?
  [ "$finished" = 0 ] || return
  finished=1
  release_vote || finish_status=1
  [ -z "$watchdog_pid" ] || kill "$watchdog_pid" 2>/dev/null || true
  if tar -czf "$archive" -C "$work" .; then
    chmod 0644 "$archive"
    printf '\nSaved: %s\n' "$archive"
    rm -rf "$work"
  else
    rm -f "$archive"
    printf 'Archive failed; logs retained in %s\n' "$work" >&2
    finish_status=1
  fi
  trap - EXIT
  exit "$finish_status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

snapshot() {
  printf '\n=== %s ===\n' "$1"
  date -u
  for supply in battery usb main bms cp_master cp_slave; do
    for field in status online capacity temp voltage_now current_now current_max voltage_max power_now input_current_limit input_power_limit constant_charge_current constant_charge_current_max charge_type usb_type real_type pd_active; do
      path="/sys/class/power_supply/$supply/$field"
      [ -f "$path" ] && [ -r "$path" ] || continue
      printf '%s=' "$path"
      bounded head -c 512 "$path" 2>&1
      printf '\n'
    done
  done
  for group in charge_interface quick_charge charger_thermal; do
    for field in iin_limit ichg_limit power_limit current_limit current_ration quick_charge_type charge_enable input_suspend wired_ctrl_limit wired_thermal_limit; do
      path="/sys/class/xm_power/charger/$group/$field"
      [ -f "$path" ] && [ -r "$path" ] || continue
      printf '%s=' "$path"
      bounded head -c 1024 "$path" 2>&1
      printf '\n'
    done
  done
}
{
  uname -a
  printf 'mode=%s\nclient=%s\n' "$mode" "$client"
  for prop in ro.product.device ro.soc.model ro.vendor.build.fingerprint ro.build.version.sdk; do
    printf '%s=' "$prop"; getprop "$prop"
  done
  for path in /sys/class/power_supply/battery/constant_charge_current_max /sys/class/power_supply/main/constant_charge_current_max "$node"; do
    [ ! -e "$path" ] || ls -l "$path"
  done
} > "$work/device.txt" 2>&1

if [ "$mode" = observe ]; then
  echo 'Read-only recording. Keep charger connected.'
  echo 'First 20 seconds: leave Scene unchanged.'
  echo 'Then lower its charging limit for 30 seconds, raise it to your usual setting,'
  echo 'and finally restore your original Scene setting before recording ends.'
  echo 'This script does not change or restore settings made by Scene.'
  i=0
  while [ "$i" -lt "$seconds" ]; do
    snapshot "observe $i" >> "$work/samples.txt" 2>&1
    i=$((i + 1))
    sleep 1
  done
else
  [ "$(getprop ro.product.device)" = pudding ] || { echo 'Probe supports pudding only.' >&2; exit 1; }
  [ -d /sys/module/mca_strategy_buckchg ] || { echo 'MCA buck module is not loaded.' >&2; exit 1; }
  [ -w "$node" ] || { echo 'MCA input-current control is unavailable.' >&2; exit 1; }
  [ "$(cat /sys/class/power_supply/usb/online)" = 1 ] || { echo 'Connect a wired charger.' >&2; exit 1; }
  module=/vendor_dlkm/lib/modules/mca_strategy_buckchg.ko
  [ -f "$module" ] || { echo 'Expected vendor module is unavailable.' >&2; exit 1; }
  digest=$(sha256sum "$module") || exit 1
  [ "${digest%% *}" = ab9edb92cdd5a58d38ee4ae509435ab94b42587fea8004618998e9ad1fdb851c ] || {
    echo 'Unrecognized MCA implementation; no writes made.' >&2; exit 1;
  }
  echo 'Testing an independent 500 mA buck input limit for 8 seconds, then releasing it.'
  snapshot before >> "$work/samples.txt" 2>&1
  # Arm cleanup before the first write, including partially successful writes.
  vote_active=1
  # Independent fallback if the recording process is killed before its trap.
  # This only releases this unique client's vote; it never raises OEM limits.
  (
    trap - EXIT INT TERM
    trap '' HUP
    sleep 45
    bounded sh -c 'printf "%s\n" "$2" > "$1"' sh "$node" "$client buck 0"
  ) >/dev/null 2>&1 &
  watchdog_pid=$!
  write_vote 500 || exit 1
  i=0
  while [ "$i" -lt 8 ]; do
    snapshot "limited $i" >> "$work/samples.txt" 2>&1
    i=$((i + 1))
    sleep 1
  done
  release_vote || exit 1
  i=0
  while [ "$i" -lt 8 ]; do
    snapshot "released $i" >> "$work/samples.txt" 2>&1
    i=$((i + 1))
    sleep 1
  done
fi
