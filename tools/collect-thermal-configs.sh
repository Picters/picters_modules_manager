#!/system/bin/sh
# Read-only Xiaomi thermal policy collector.
# Run: su -c 'sh /sdcard/collect-thermal-configs.sh'
set -u
umask 077
if [ "$(id -u)" != 0 ]; then
  echo "Run: su -c 'sh /sdcard/collect-thermal-configs.sh'" >&2
  exit 1
fi

thermal_name="Picters-Thermal-Configs-$(date +%Y%m%d-%H%M%S)-$$"
thermal_dir=$(mktemp -d "/data/local/tmp/${thermal_name}.XXXXXX") || exit 1
thermal_archive="/sdcard/${thermal_name}.tar.gz"
mkdir -p "$thermal_dir/files"
printf 'Collecting thermal configuration files...\n'

bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 2 15 "$@"
  elif command -v toybox >/dev/null 2>&1; then
    toybox timeout -k 2 15 "$@"
  else
    echo "Skipped (timeout unavailable): $*"
  fi
}

{
  date -u
  uname -a
  for thermal_prop in ro.product.device ro.product.model ro.soc.model ro.board.platform ro.build.version.release ro.build.version.sdk ro.vendor.build.fingerprint ro.vendor.build.version.sdk ro.vendor.build.security_patch; do
    printf '%s=' "$thermal_prop"
    getprop "$thermal_prop"
  done
} > "$thermal_dir/device.txt" 2>&1

# Only configuration directories and filenames; no user files or app data.
{
  for thermal_root in /vendor/etc /odm/etc /system_ext/etc /product/etc; do
    for thermal_file in "$thermal_root"/*thermal* "$thermal_root"/powerhint*.xml; do
      [ -f "$thermal_file" ] && printf '%s\n' "$thermal_file"
    done
  done
  for thermal_root in /vendor/etc/thermal /odm/etc/thermal /vendor/etc/thermal-engine /odm/etc/thermal-engine /data/vendor/thermal /data/thermal; do
    [ -d "$thermal_root" ] || continue
    find "$thermal_root" -maxdepth 3 -type f 2>/dev/null | while IFS= read -r thermal_file; do
      case "$thermal_file" in
        *.conf|*.cfg|*.json|*.xml|*.bin|*.ini) printf '%s\n' "$thermal_file" ;;
      esac
    done
  done
  # Include loader binaries and loaded crypto/thermal libraries for offline analysis.
  for thermal_file in /vendor/bin/mi_thermald /system/bin/mi_thermald /odm/bin/mi_thermald /vendor/lib64/libthermalclient.so /vendor/lib64/libthermalioctl.so /vendor/lib64/libthermalconfig.so /data/vendor/thermal/decrypt.txt /data/vendor/thermal/thermal-global-mode /data/vendor/thermal/thermal-qos-config /data/vendor/thermal/thermal-qos-parameters /data/vendor/thermal/thermal-qos-predict-parameters; do
    [ -f "$thermal_file" ] && printf '%s\n' "$thermal_file"
  done
  for thermal_pid in $(pidof mi_thermald 2>/dev/null); do
    thermal_exe=$(readlink "/proc/$thermal_pid/exe" 2>/dev/null)
    case "$thermal_exe" in
      /vendor/*|/system/*|/odm/*) [ -f "$thermal_exe" ] && printf '%s\n' "$thermal_exe" ;;
    esac
    awk '{print $NF}' "/proc/$thermal_pid/maps" 2>/dev/null | sort -u | while IFS= read -r thermal_library; do
      case "$thermal_library" in
        /vendor/*thermal*.so|/odm/*thermal*.so|/system/*thermal*.so|/vendor/*crypto*.so|/system/*crypto*.so|/apex/*crypto*.so|/vendor/*ssl*.so) [ -f "$thermal_library" ] && printf '%s\n' "$thermal_library" ;;
      esac
    done
  done
  for thermal_file in /vendor/etc/perf/targetsysnodesconfigs.xml /vendor/etc/perf/targetresourceconfigs.xml /vendor/etc/perf/commonsysnodesconfigs.xml /vendor/etc/perf/thermalbreakboostconfig.xml; do
    [ -f "$thermal_file" ] && printf '%s\n' "$thermal_file"
  done
  for thermal_root in /vendor/etc/init /odm/etc/init /system/etc/init /system_ext/etc/init; do
    for thermal_file in "$thermal_root"/*.rc; do
      [ -f "$thermal_file" ] || continue
      if grep -qiE 'thermal|thermald|mi_therm' "$thermal_file"; then
        printf '%s\n' "$thermal_file"
      fi
    done
  done
} | sort -u > "$thermal_dir/candidates.txt"

thermal_total=0
while IFS= read -r thermal_file; do
  [ -f "$thermal_file" ] || continue
  if [ ! -r "$thermal_file" ]; then
    printf 'Unreadable: %s\n' "$thermal_file" >> "$thermal_dir/collection-errors.txt"
    continue
  fi
  thermal_bytes=$(wc -c < "$thermal_file")
  if [ "$thermal_bytes" -gt 16777216 ] || [ "$((thermal_total + thermal_bytes))" -gt 67108864 ]; then
    printf 'Size limit: %s\n' "$thermal_file" >> "$thermal_dir/collection-errors.txt"
    continue
  fi
  thermal_relative=${thermal_file#/}
  mkdir -p "$thermal_dir/files/${thermal_relative%/*}"
  if cat "$thermal_file" > "$thermal_dir/files/$thermal_relative"; then
    thermal_total=$((thermal_total + thermal_bytes))
    ls -l "$thermal_file" >> "$thermal_dir/copied-files.txt"
  else
    printf 'Copy failed: %s\n' "$thermal_file" >> "$thermal_dir/collection-errors.txt"
  fi
done < "$thermal_dir/candidates.txt"

{
  printf '=== Processes ===\n'
  ps -A | grep -iE 'thermal|thermald|powerhal|powerkeeper|perfd' || true
  printf '\n=== Services ===\n'
  bounded service list | grep -iE 'thermal|power|perf' || true
  printf '\n=== Thermal storage permissions ===\n'
  for thermal_path in /data/vendor/thermal /data/thermal /vendor/etc/thermal /odm/etc/thermal; do
    [ -e "$thermal_path" ] || continue
    ls -ld "$thermal_path"
    ls -l "$thermal_path"
  done
  printf '\n=== Mounts ===\n'
  cat /proc/mounts
} > "$thermal_dir/thermal-runtime.txt" 2>&1

{
  for thermal_zone in /sys/class/thermal/thermal_zone*; do
    [ -d "$thermal_zone" ] || continue
    printf '\n[%s]\n' "$thermal_zone"
    for thermal_field in type temp mode policy; do
      [ -r "$thermal_zone/$thermal_field" ] || continue
      printf '%s=' "$thermal_field"
      cat "$thermal_zone/$thermal_field"
    done
    for thermal_trip in "$thermal_zone"/trip_point_*; do
      [ -f "$thermal_trip" ] || continue
      ls -l "$thermal_trip"
      cat "$thermal_trip" 2>&1
    done
  done
} > "$thermal_dir/thermal-zones.txt" 2>&1

{
  for thermal_path in /sys/class/kgsl/kgsl-3d0/devfreq /sys/class/devfreq/*; do
    [ -e "$thermal_path" ] || continue
    ls -ld "$thermal_path"
    ls -l "$thermal_path/" 2>&1
    for thermal_field in name governor available_governors min_freq max_freq; do
      [ -r "$thermal_path/$thermal_field" ] || continue
      printf '%s/%s=' "$thermal_path" "$thermal_field"
      cat "$thermal_path/$thermal_field"
    done
  done
} > "$thermal_dir/gpu-interfaces.txt" 2>&1
{
  for thermal_pid in $(pidof mi_thermald 2>/dev/null); do
    printf '\n=== Loader %s ===\n' "$thermal_pid"
    readlink "/proc/$thermal_pid/exe"
    cat "/proc/$thermal_pid/maps"
  done
  for thermal_node in /sys/class/thermal/thermal_message/sconfig /sys/class/thermal/thermal_message/temp_state /sys/class/thermal/thermal_message/boost; do
    [ -r "$thermal_node" ] || continue
    printf '%s=' "$thermal_node"
    cat "$thermal_node"
  done
} > "$thermal_dir/loader.txt" 2>&1
bounded dumpsys thermalservice > "$thermal_dir/thermal-service.txt" 2>&1 || true

cat > "$thermal_dir/README.txt" <<'NOTE'
Read-only thermal configuration and loader collector for Picters (v2).
files/ preserves original paths and exact file contents, including binary policies.
No service is stopped; no thermal profile, threshold or system setting is changed.
Missing/unreadable files and size limits are recorded. No logcat or app data collected.
NOTE

if tar -czf "$thermal_archive" -C "$thermal_dir" .; then
  rm -rf "$thermal_dir"
else
  rm -f "$thermal_archive"
  thermal_archive="/sdcard/${thermal_name}.tar"
  if tar -cf "$thermal_archive" -C "$thermal_dir" .; then
    rm -rf "$thermal_dir"
  else
    rm -f "$thermal_archive"
    printf '\nArchive failed. Reports retained: %s\n' "$thermal_dir" >&2
    exit 1
  fi
fi
printf '\nSaved: %s\n' "$thermal_archive"
