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
`buck_input`, `buck_charge_curr`, `single_chg_cur`, and `multi_chg_cur`. Disabled / Off calls
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

## 2026-11-01 device investigation

Build 18 capture with target 120 W contains a real 1000 mA winning
`volt_thermal_limit` vote on the buck charge-current election and a 1600 mA
`volt_limit` input vote. All samples still have the app request enabled, so this
archive does not test disable/release or the reported 0.2 W event.

The captured buck module references `volt_thermal_limit` in
`strategy_buckchg_set_5v_ichg` (0x4738) and
`strategy_buckchg_set_9v_ichg` (0x4810). Both use ordinary vendor votes, not a
Picters-owned limit. The fourth election name `buck_charge_curr` is confirmed
by the buck probe's .rodata+0x17c6 and charge-limit callback at 0x436c.
The newly added buck-current vote makes a low Picters target cover the normal
charging path too; it cannot raise an existing lower OEM ceiling.

The user reports that charging accelerates with the display off. This establishes
a useful correlation, not the exact cause: compare actual charger type, screen
state, buck votes and charge-pump state in the same session. Do not overwrite
`volt_thermal_limit`, force charge-pump enable, or treat `apdo_max=90` as measured
power based solely on this archive. Thermal Off in the app edits selected
CPU/GPU rules; its policy builder deliberately retains charging sections.

The new read-only `effective_limits` driver attribute reports all four winning
current ceilings and client names, separately from `power_target` and measured
watts. It imports `mca_get_effective_result` (CRC 0x883255f3) and
`mca_get_effective_client` (CRC 0x462d3f3e), as present in the supplied MCA ABI.
Compilation against the existing A17 test kernel passed; no updated module
was installed on a phone and no sustained-fast-charge result is established.

The repository now sends charging restore even when the helper health flag has
fallen to inactive, provided the verified charging backend is available. This
prevents a failed status/worker from hiding a remaining leased vote. Charging
apply failures are now shown in the UI instead of silently leaving the previous
selection. These changes remain separate from the missing screen-mode backend.

The later screen-off recording shows battery-terminal charging rising from
about 4 W to 34.06 W, with charge-pump bus voltage 18212 and current 2113
in its captured native units. The quick_charge_type attribute still reads 0,
so this field must not be used alone to declare fast charging inactive.
Its initial sample also has a transient positive battery current (net discharge);
absolute current alone must not be labelled charging power.
The buck vote changes 1000 to 3000 mA during the recording; it is then suspended
by wire_qc while the pump works. Therefore removing the buck ceiling alone
cannot be claimed to enable high-power pump charging.

In the captured mca_smart_charge binary, smart_charge_panel_notifier_cb
(0x20d4) queues screen-status propagation and the policy worker.
smart_charge_set_screen_status_work (0x29cc) calls
platform_class_buckchg_ops_set_screen_status. This confirms a vendor screen
input; it does not establish a reversible user fast-charge override.
The new screen-on switch below the power slider is preview-only. Production
disables it with an explanatory tooltip until a verified backend is available;
it does not spoof display state or report the mode applied.

## Normal Xiaomi power-boost probe

The matched `mca_smart_charge.ko` (SHA256
`bc9321a44fb892f77c18739e83fbe956a06974f4a9946cf16ac01db1f2d605d7`)
contains an ordinary power-boost control through
`/sys/class/xm_power/charger/smart_charge/smart_chg`. The vendor init rc
confirms this path. The status read is a decimal composite feature mask.
The store handler routes smart_chg (attribute0) to the control-message decoder.
Decoder bit2 selects power boost; bit0 enables it. Command5 enables that one
feature, command4 disables it. Other feature bits must not be sent as a combined
command: the decoder rejects multiple selected features.

At 0xbd0–0xbe4 the decoder updates the power-boost state and calls
smartcharging_handle_power_boost; at 0xf2c onward this forwards the normal boost
setting through registered vendor operations. It does not by itself establish
screen-on override behavior, a guaranteed wattage, or bypass of protections.

`tools/test-power-boost.sh` matches the vendor module, saves the original boost
bit, enables the normal boost command, verifies readback and reasserts this one
feature if software clears it during twenty two-second sample intervals. It
restores the original boost bit on completion or normal exit signals, retaining
other OEM feature bits. A separate ninety-second fallback worker also attempts
restoration if the collector is killed; device reboot remains the fallback if
the entire process group is killed. It reports failed restoration explicitly.
The script never edits thermal limits, display state, voltage ceilings or safety
partitions. Run with the screen on and charger connected; the resulting archive
is needed before connecting this backend to the app's screen-on switch.

Three isolated script tests (four fixture cases) pass: preserve an initially
disabled/enabled boost bit and unrelated bits, reject an unknown vendor before
writing, and restore after a rejected enable. These emulate the documented
command ABI; they are not phone verification.

## Remaining screen-on limiter investigation

The user's adapter is rated90W with its original cable. Sustained100W cannot be
promised from this adapter. Xiaomi's official global Xiaomi17 specifications
state100W wired HyperCharge (https://www.mi.com/global/product/xiaomi-17/specs/),
which describes the phone capability, not this adapter's measured delivery.

The power-boost phone test at20261101-001344 contains20 screen-Awake samples
over48s. All masks are68 (original64), with battery power4.341–4.385W and
42.0–42.8C. Buck volt_thermal_limit remains1000mA, wired_ctrl_limit14, and pump
current remains3–5 in native units. Therefore reasserting boost cannot be treated
as a solution. The script verified restoration of the original boost bit.

The original thermald-devices.conf maps thermal_fcc_override to wired_chg_curr
and battery to a battery cooling device. The app's Thermal Off changes selected
CPU/GPU policy rules while preserving the charging rules. Both those rules and
other charging software remain candidates; no individual writer is yet proven.

A micharge-service screenStateChangedThread disassembly also exists, but its
notification path opens a HID device and sends an o1g packet. This may belong
to an accessory, so it must not be identified as the internal charging limiter
merely because it contains screen-state strings. The service exposes a generic
wired_ctrl_limit attribute; presence of a setter does not prove it authored14
in this recording. The MCA smart-charge module separately propagates screen
state to the vendor buck/ADSP implementation.

`tools/collect-charging-path.sh` now records the relevant raw device-tree tables,
mi_thermal_interface and MCA binaries/hashes, actual thermal files, cooling-device
states, OEM screen/charging policy attributes, negotiated/charge-pump readings
and filtered charging logs. It makes no control writes. Recording includes
50 samples with power-manager screen state; sequential values are not atomic.
An isolated smoke test runs the actual script, checks archive content and
serial-property exclusion, and confirms all control nodes remain unchanged.
No additional charging path is connected to the UI before identification and
reversible device verification.

## Synchronized path capture at96%

The20261101-002800 archive has50 samples, all at96% SOC. PD_PPS and the
charger common power_max both report90W capability. Awake has wired levels11
then7, Dozing clears the level to0. The extracted15x10 wired_thermal table
matches the reported buck-current ceilings: level11→2000mA,7→2600mA, and
0 allows the default3000mA ceiling. Even with level0, battery power remains
approximately4W at this near-full SOC. Therefore this recording establishes
the screen-linked policy transition, but cannot validate maximum charging
power or justify removing voltage/current cutbacks.

104 ODM and102 active policies decoded with the real Java codec. CPU/GPU Off
retains charging policies, as intended. The HAL messages for wired_ctrl_limit
are reads; they do not establish it as the author of the levels.

The collector is now bounded to approximately100 seconds of sampling plus the
last sequential snapshot, rather than50 potentially slow full snapshots.
Initial configuration capture and archive creation take additional time.
A lower-SOC repetition of this same read-only capture is needed to evaluate
the screen-on maximum with the90W adapter.
