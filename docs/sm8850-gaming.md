# SM8850 Gaming investigation

Local only; no device runtime or FPS validation has been performed.

## Implemented

The application discovers the installed CPU policies and KGSL frequency table,
restores the supported stock ceilings and releases its own CPU maximum QoS
requests. Gaming selects `performance` on writable CPU/GPU domains advertising
that governor, with readback verification and rollback. Leaving Gaming restores
the previous governors. Minimum frequency locking remains independent.

The kernel fragment enables CPUFreq and devfreq performance governors. The local
devfreq implementation requests DEVFREQ_MAX_FREQ; downstream driver and thermal
constraints still determine the actual frequency. This is not an overclock or a
verified removal of Xiaomi vendor limits. Partial governor support is possible.

## Platform-specific follow-up

1. Capture actual SM8850 CPU policy tables, KGSL governors, frequency tables,
   effective limits and Power/Game service availability using the read-only
   `tools/inspect-gaming-device.sh`. Desktop preview values are demo data.
2. Verify each advertised governor is accepted and stays active during a game;
   inspect whether Xiaomi Power HAL changes it or places another maximum vote.
3. Inspect vendor KGSL source/interfaces before adding any vendor power-level
   controls. This GKI checkout does not contain the downstream KGSL driver.
4. Evaluate supported Android Game Mode/Power HAL integration per selected game.
   ADPF hint sessions belong to game workload threads; a manager session is not
   a replacement for integrating hints into the game.
5. Compare frame-time distribution, sustained FPS, frequency residency, power and
   temperature on the same game/settings. A higher requested clock is not proof
   of a sustained gaming improvement.

Do not invent fixed GHz values, scheduler boosts or vendor sysfs paths from the
chip's marketing name. Adreno HPM, Tile Memory Heap and mesh shading depend on
the graphics stack and game support; they are not generic sysfs unlocks.

## Primary references

- Qualcomm platform: https://www.qualcomm.com/smartphones/products/8-series/snapdragon-8-elite-gen-5
- Qualcomm gaming/HPM: https://www.qualcomm.com/smartphones/features/snapdragon-elite-gaming
- CPUFreq performance governor: https://www.kernel.org/doc/html/latest/admin-guide/pm/cpufreq.html
- Android ADPF: https://developer.android.com/games/optimize/adpf
- Android game power mode: https://source.android.com/docs/core/perf/boost

## Xiaomi 17 thermal capture, 2026-10-30

The supplied report identifies pudding/SM8850, OS4.0.0.15 Android 17, vendor
OS4.0.0.11 reporting Android 16, and a running 6.12.69 Picters kernel.
KGSL identifies Adreno840v2 and exposes a 1.2 GHz maximum. CPU policy0 exposes
3.6288 GHz; policy6 reports a 4.608 GHz hardware ceiling but was capped at
2.112 GHz in the snapshot. That snapshot alone does not identify the vote owner.
The captured GPU devfreq governor directory yielded no governor values, so
CPU performance-governor support does not establish GPU governor availability.

The second archive contains 226 files. `/odm/etc/thermal-normal.conf` is 6768
bytes of non-text binary data (length divisible by 16, entropy ~7.97 bits/byte).
`/data/vendor/thermal/config/thermal-normal.conf` is 16 bytes; several other
custom-policy files contain the same 16 bytes. These observations suggest an
encoded/encrypted container, but neither cipher nor plaintext syntax is verified.
`/vendor/etc/thermal-engine.conf` is the stock empty placeholder and does not
prove that the Xiaomi thermal service loads Qualcomm-style text policies.
Do not treat the 16-byte files as editable threshold records or overwrite them.

Battery sensor values, HAL severity thresholds and CPU/skin policies are distinct.
The captured `battery` and `batt_temp` thermal zones have no exported trip values.
A battery target cannot guarantee that CPU, skin, charging or hardware mitigation
waits for that temperature. The UI 25–65 °C range and detached Off endpoint are
preview selections only. The middle value 45 °C is not a validated battery limit.

Next format investigation requires the actual loader (`mi_thermald` and its
configuration/crypto libraries) or a verified matching source implementation,
plus confirmation of policy activation and stock restoration on this firmware.
No thermal service, trip or on-device profile has been modified.


### Verified codec investigation

Offline analysis now confirms that AES-128-CBC with the established Xiaomi
`thermalopenssl.h` key/IV decodes 105 captured policies with exact byte-for-byte
re-encryption. Of those, 95 decode to empty contents, and 10 contain text. Four
other files are plaintext. 97 files are still classified unknown; these are not
passed off as decrypted or used to generate device policies. In particular the
ODM normal/nolimits/game policies fail this codec. The vendor mapping decodes,
but is only a scene-to-filename map, not a set of throttling thresholds.

`tools/analyze-thermal-archive.py` records original SHA-256 hashes, sizes, codec
status and validated plaintext. It rejects archive traversal and oversized
members and never writes device paths. Verified output is in the sibling
`artifacts/v1.4/thermal-analysis-verified` directory.

The collector v2 also captures mi_thermald, its loaded thermal/crypto libraries,
loader maps, and the small vendor thermal control files. These are needed to
identify the ODM loader codec and actual activation/restore behavior. No device
backend is enabled while that format remains unresolved.

The preview slider color now interpolates from the existing primary color at
25 °C to red at 65 °C, with the Off endpoint remaining red. This visual scale is
not a validated temperature safety scale.

Codec implementation references (read as code, not execution instructions):
- https://github.com/helloklf/vtools/blob/master/mi-thermal-config/miui-thermal.go
- https://github.com/adithya2306/mi-thermal-crypt/blob/master/mi-thermal-crypt.c


### Loader v2 dump: key recovery

Captured mi_thermald SHA-256:
`df25b03dfb7081c6b85e130a457f48b049c0f2056979ee407208d5fdf86b057e`.
The loader has both legacy AES-CBC and a white-box-wrapped policy key. Property
`persist.vendor.aes_whitebox.encrypt` selects the path. At `0xa7d38` the loader
calls key recovery (`0xb6fc0`); it then uses the recovered 16 bytes as both key
and IV for EVP AES-128-CBC (`0xa7d4c`–`0xa7d5c`). The wrapped-key hex is at
`0xd455a`. Its CBC unwrapping calls a pure table-driven block routine at `0xc8bc8`.

The local helper `tools/recover-thermal-loader-key.py` pins the loader hash,
emulates only that block routine in memory, blocks interrupts, bounds execution,
and validates the full 16-byte PKCS#7 padding block. Recovery succeeded and
repeated output was identical. No Android daemon or host binary from the archive
was run. The recovered key is a thermal-file-format key, not a signing key.

`tools/analyze-thermal-archive.py --key-file ...` now supports that derived key,
requiring valid text, strict padding and exact re-encryption before accepting a
policy. Synthetic fixtures verify both codec paths and rejection behavior.
The original archive files disappeared from Downloads during this investigation,
before ODM ciphertext was copied into the artifact directory. Thus the derived
key has NOT yet been validated against an actual ODM policy from this device.
The previously decoded legacy files and the loader copy are preserved locally.
Device application remains unavailable until the stock policy contents, activation
and rollback are verified. No new archive or production profile was published.

### ODM format resolved and validated

The user restored the source archives. A retained copy of the latest archive is
now under `artifacts/v1.4/thermal-loader/`. With the recovered key as BOTH AES key
and IV, all 206 thermal configuration files validate: 202 encrypted policies and
four plaintext files. The encrypted set consists of 95 empty policies and 107
nonempty text policies; no unknown codecs remain. Every accepted encrypted file
round-trips exactly to its original ciphertext. The earlier missing-input blocker
and unknown-ODM-codec conclusions are resolved.

The `normal` policy uses a multi-sensor body-temperature formula for CPU/GPU
mitigation, not a direct battery threshold. It also contains independent charging,
RF, brightness, battery-level and emergency/awareness rules. Existing custom
normal/nolimits files in `/data/vendor/thermal/config` decode to empty contents;
these are not a factory default baseline.

`tools/build-thermal-profile.py` creates OFFLINE drafts from validated stock text.
It changes only whitelisted CPU/GPU/boost thermal sections using the body formula,
retargets them to `battery`, anchors their first trigger at the selected Celsius
value, and preserves relative trigger spacing, hysteresis and target tables.
Reverse/battery-level/awareness, charging and mixed-device rules are untouched.
Off omits only those custom performance rules; it does not disable hardware or
all vendor thermal mitigation. No claim of complete throttling removal is made.
For the real normal policy, five sections change; every other section remains
byte-for-byte identical. Drafts at 45/55/65 C are generated, encrypted and checked
by exact decryption. They are not installed and are not flashable release ZIPs.

Loader disassembly at 0xa7cd8 uses legacy key/IV pointers for legacy/custom files;
0xa7d38 unwraps the white-box key and passes it as both key and IV for the stock
path. Deployment must honor that distinction, identify the active scenario,
back up current overrides, verify the loader accepted the generated policy, and
verify restoring stock. None of those runtime writes/tests has occurred yet.
