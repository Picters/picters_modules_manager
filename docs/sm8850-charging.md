# Xiaomi 17 charging control investigation

Status: the 1–120 W target, thermal dependency and native transport are wired
into the app. A new external `picters_charging` module and `chargingctl.sh` are
prepared for PictersKernelPack. The Android transport compiled in the signed arm64 1.4.0 APK. Kernel adapter
compilation/packaging are in progress; nothing has been run on a phone.
This does not establish verified charging behavior.

## Prepared implementation

The kernel adapter imports only `mca_find_votable` and `mca_vote` directly. The
real vendor export CRCs are pinned in `picters_charging/vendor.symvers`:
`0xc552fc72` and `0xd888adf1`. No KMI structures or exported symbols are changed.
The adapter has no private-structure access, dynamic symbol lookup or CFI bypass.

Its own `picters_charging` client votes on the existing minimum elections
`buck_input`, `single_chg_cur`, and `multi_chg_cur`. Disabled / Off calls
`mca_vote(..., false, 0)` for its own client, rather than writing a zero current
through the quick-charge sysfs setter. A failed partial update releases its votes.
The buck input-current target is derived from USB voltage; quick-charge battery
current targets are derived from battery voltage, refreshed every two seconds.
This is an approximate charging target, **not an exact adapter-input W cap**:
system load, conversion losses, negotiation and OEM limits still affect it.
The selected target does not guarantee measured consumption or charging speed.

The module starts with no votes. The policy worker refreshes a 30-second lease;
when refresh stops, the kernel releases the app votes. Unplugging the cable
releases votes while retaining the selected target for reconnection. Off releases
all app votes and permits the OEM algorithm's normal maximum. No temperature,
battery-safety partition, thermal-client vote or negotiated adapter limit is
bypassed. It cannot command a 100 W adapter to deliver 120 W.

The root helper checks the installed module's exact kernel release, the captured
MCA vendor module hashes and adapter API before use. It persists only when Keep
after reboot is selected and Custom throttling is still Off. It restores stock
on disable, uninstall, a changed vendor, thermal leaving Off, or a rejected policy.
The app restores charging before changing thermal and reconciles actual state
after a failure. The bridge is hidden from manual module toggles and excluded
from the generic boot-loader loop; only the guarded charging helper loads it.

Both kernel build paths include the same adapter source, but runtime support is
currently limited to the captured vendor ABI. An Android 16 vendor with different
MCA binaries is unsupported until its ABI is established; its mere system SDK is
not used to guess compatibility. Kernel/module build and
runtime behavior remain pending; native Android compilation passed. No new phone diagnostics are required by this
preparation; the user opted to proceed without those runs.

## Retained device capture

`artifacts/v1.4/charging-analysis/latest` in the project parent contains the
bounded extraction of `Picters-Charging-20261030-194959-7169.tar.gz`.
The original archive is retained beside it. System files were inspected offline;
no vendor executable was run and no phone setting was changed.

Device: pudding / SM8850, system SDK 37, vendor SDK 36, with vendor fingerprint
`Xiaomi/pudding_eea/pudding:16/BQ2A.260225.001-BP2A.250705.008/OS4.0.0.11.XPCMI:user/release-keys`.
The capture runs Linux 6.12.69 from the user's kernel.

## Confirmed interfaces and limitations

- `/sys/class/power_supply/usb/input_current_limit` is writable. Its MCA handler
  `usb_psy_set_prop` at `0x4220` forwards the integer to strategy 0/config 0. A
  successful write alone does not establish control of the separate quick-charge
  path, its unit, or an input-power limit across all charging modes.
- USB current is obtained from the buck driver's bus-current operation without
  conversion (`usb_psy_get_prop`, `0x4124`–`0x4134`). The captured USB value is
  3000 while UCSI reports 3000000. It must not be treated generically as µA.
  This buck reading is not established as the sum of the charge-pump paths.
- `/sys/class/xm_power/charger/charge_interface/iin_limit` and `ichg_limit`
  use three whitespace-separated tokens: client, path type, value. The common
  parser at `0x950`–`0x974` requires all three. Reading returns effective-client
  information, not the original request of an individual client.
- Buck input current accepts a signed integer. Zero disables that client's
  vote; nonzero enables it (`strategy_buckchg_if_set_input_cur`, `0x5aa8`).
  Clients containing `MTBF`/`mtbf` select the override API. The application must
  not use those names or override other thermal/charging clients.
- Quick `ichg_limit` is different: it requires a value formatted `%d#%d`, then
  enables two votes (`strategy_quickchg_if_set_chg_cur`, `0xc140`). Therefore
  reusing the buck's zero-reset rule would enable zero-valued quick-charge votes,
  not remove them. A reversible quick-charge reset has not been established.
- `quick_charge/current_limit` is attribute ID 5 in the captured module. Although
  the file mode is writable, its store handler (`0x5fa4`) does not handle ID 5;
  it returns the write count without updating anything. Do not use it as a
  working control or accept a successful write as verification.
- `quick_charge/current_ration` is attribute ID 6. Its handler can call
  `charger_partition_write_batt_safe_ilim` (`0x6574`). This is not a generic W
  selector and may persist battery-safety settings; it is not an app control.
- The captured `charge_interface/power_limit` read is empty. A writable filename
  does not establish an implemented wired power-limit operation.
- `typec/apdo_max=90` describes an advertised capability; it is not proof of
  current consumption, nor permission to request an arbitrary current.

`mca_voter` exports separate normal-vote and override APIs. The prepared adapter
manages only its own vote, releases it explicitly, and retains the original
vendor thermal/protection votes. Runtime reset remains unverified. No CFI bypass, private-structure poking,
temperature spoofing or charger-partition writes were added.

## Scene comparison and phone tests

The public Scene sources at
[fast_charge.sh](https://github.com/helloklf/vtools/blob/master/app/src/main/assets/addin/fast_charge.sh)
set `constant_charge_current_max` in microamps. This is a battery-current
setting, not an adapter-watt request. The captured pudding battery node is
read-only and returns zero. The public implementation does not establish which
backend the current Scene 8 release uses on this firmware.

`tools/test-charging.sh observe 120` records only whitelisted charger nodes while
the user changes and restores Scene's limit. It does not change phone settings.
`probe-buck` separately tests a unique 500 mA MCA buck input-current vote, with
reset on normal exit/signals and a separate 45-second fallback reset process.
It refuses other devices, unavailable wired charging, and a vendor module whose
hash differs from the analyzed implementation. It does not exercise the quick
charge current setters or disable protection. A successful write is logged as a
request; only phone telemetry can establish whether charging responds.
Both modes save a timestamped archive directly in `/sdcard`.

## Module identity

SHA-256 of the analyzed vendor modules:

| Module | SHA-256 |
| --- | --- |
| mca_charge_interface.ko | `5ed3480b1367052162956d617f74b177d19f5919094ccdf9a7a595ce8459d5d9` |
| mca_strategy_quickchg.ko | `95f9802c72595131f7b155bd9ed05ef924dd85d819e57bc23ffdc6da0011eb8e` |
| mca_strategy_buckchg.ko | `ab9edb92cdd5a58d38ee4ae509435ab94b42587fea8004618998e9ad1fdb851c` |

Reproduce the observations with `llvm-readelf -Ws/-p/-r` and `llvm-objdump -dr`
on these files. Disassemblies of the common parser and selected quick-charge
controls are retained under `artifacts/v1.4/charging-analysis`.

## Behavior prepared in the app

- Thermal and charging share one controller and Keep after reboot flag.
- Charging power requires the applied Custom throttling setting to be Off.
- Leaving thermal Off clears the app's power selection and disables its card.
- The slider selects whole W from 1 through 120, or the separate Off endpoint.
  Application starts on release; repeated changes are blocked until it completes.
- Off means no app-imposed cap. It does not mean forcing 120 W or overriding the
  device, cable, adapter, battery, temperature or negotiated-protocol limits.
- Demo selections stay in memory. Production stores requested policies through
  the pack helper. Neither source tests nor successful writes prove real watts.
