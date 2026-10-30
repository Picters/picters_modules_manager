# Picters SystemPack performance service reference.
# Generated service source: Picters_Kernel_CI_Center/ci_core_rs/src/build.rs.
# Gaming governors and frequency minimums are independent of frequency caps.
# enabled 0 leaves all domains at their ordinary boot defaults.

CONFDIR=/data/adb/picters_modules_manager

# --- CPU/GPU performance caps (perf.conf) ---------------------------------
# The vendor perf HAL (perfd) OWNS scaling_max_freq and rewrites it on load /
# thermal events, so a one-shot cap doesn't hold. On a kernel with the in-kernel
# FREQ_QOS ceilings the "kcpu" line below pins the CPU cap once and perfd can't
# undo it; the loop stays for the GPU and for kernels without them. The app only
# ever writes real OPP-table frequencies (never above stock). pmm_apply_perf
# stays idle while persistence is disabled, so enabling it later also works.
# Runs in the background so it never blocks boot.
# PMM_PERF_V2: independent governors, minimums and kernel QoS floors.
PERF_CONF=$CONFDIR/perf.conf
pmm_perf_enabled() {
  [ -f "$PERF_CONF" ] || return 1
  en=0
  while read -r k a _; do [ "$k" = "enabled" ] && en="$a"; done < "$PERF_CONF"
  [ "$en" = "1" ]
}

# In-kernel FREQ_QOS ceilings (CONFIG_PICTERS_PERF). perfd cannot raise these,
# so they only need pinning once — and doing it here, before the perf HAL is up,
# means the cap is already in force for the whole boot.
KCAP=/sys/kernel/picters_perf/cpu_max_freq
KMIN=/sys/kernel/picters_perf/cpu_min_freq
pmm_apply_kernel_caps() {
  [ -w "$KCAP" ] || return 1
  while read -r k rest; do
    case "$k" in
      kcpu) echo "$rest" > "$KCAP" 2>/dev/null ;;
      kmin) [ -w "$KMIN" ] && echo "$rest" > "$KMIN" 2>/dev/null ;;
    esac
  done < "$PERF_CONF"
  return 0
}
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

pmm_apply_perf_locked() {
  pmm_perf_enabled || return 1
  pmm_apply_kernel_caps
  while read -r k a b; do
    case "$k" in
      cpu) [ -n "$b" ] && [ -e "$a/scaling_max_freq" ] && echo "$b" > "$a/scaling_max_freq" 2>/dev/null ;;
      gpu) [ -n "$a" ] && [ -e /sys/class/kgsl/kgsl-3d0/max_gpuclk ] && echo "$a" > /sys/class/kgsl/kgsl-3d0/max_gpuclk 2>/dev/null ;;
      governor)
        [ "$b" = performance ] || continue
        case "$a" in
          /sys/devices/system/cpu/cpufreq/policy*/scaling_governor|/sys/class/kgsl/kgsl-3d0/devfreq/governor)
            [ -w "$a" ] && echo "$b" > "$a" 2>/dev/null ;;
        esac
        ;;
      minimum)
        case "$b" in ''|*[!0-9]*) continue ;; esac
        case "$a" in
          /sys/devices/system/cpu/cpufreq/policy*/scaling_min_freq|/sys/class/kgsl/kgsl-3d0/devfreq/min_freq)
            [ -w "$a" ] && echo "$b" > "$a" 2>/dev/null ;;
        esac
        ;;
    esac
  done < "$PERF_CONF"
  return 0
}
pmm_apply_perf() {
  # Hold one mutex from the first config read through the final sysfs write.
  # An application transaction uses the same mutex, including its rollback.
  pmm_perf_try_lock || return 0
  pmm_apply_perf_locked
  apply_result=$?
  pmm_perf_unlock
  return "$apply_result"
}
pmm_apply_perf
( sleep 20; while [ -f "$0" ]; do pmm_apply_perf; sleep 10; done ) &
