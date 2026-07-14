# Picters Modules Manager

A Flutter/Material 3 companion app for the `nethunter-oot-modules` KernelSU/Magisk module
built by [Kokuban_Kernel_CI_Center](../Kokuban_Kernel_CI_Center) — it insmod/rmmod's the
out-of-tree Wi-Fi injection and other OOT kernel drivers on demand, over root, with everything
unloaded by default.

It has **no home-screen or app-drawer icon** on purpose. It's opened via the module's Action
button in your KernelSU/Magisk manager (`am start -n com.picters.modulesmanager/.MainActivity`),
or by tapping the "Add to home screen" icon in its own app bar if you want a shortcut anyway.

## Features

- Lists every `.ko` staged under `/system/lib/modules` by the module, grouped into real
  "Wi-Fi injection" / "Other drivers" blocks, each with a load/unload `Switch` reflecting the
  live state of `/proc/modules` (not a locally-cached guess).
- **cfg80211/mac80211 are manual, not automatic.** Turning on an adapter never silently loads
  them as a hidden side effect — if they're not loaded yet you get a plain
  "Enable cfg80211 first" / "Enable mac80211 first" and nothing runs. Turning cfg80211 *on*
  does the vendor Wi-Fi teardown (`svc wifi disable` + `rmmod qca_cld3_peach_v2`) and loads our
  kernel cfg80211 — that's the one deliberate "switch to injection mode" action.
- Turning cfg80211 *off* is a best-effort **stock Wi-Fi restore**: unloads our adapters/
  mac80211/cfg80211, then tries `svc wifi enable` and, if that's not enough, searches
  `/vendor` and `/vendor_dlkm` for `qca_cld3_peach_v2.ko` and re-`insmod`s it. It checks
  `/proc/modules` afterward and tells you honestly whether it worked or whether you still need
  to reboot — it doesn't just assume success.
- **USB adapter detection**: scans `/sys/bus/usb/devices` and matches attached devices against
  a VID:PID table sourced from the `supported-device-IDs` files of the actual driver forks this
  project ships (aircrack-ng/rtl8812au, aircrack-ng/rtl8188eus, morrownr/8814au,
  morrownr/88x2bu-20210702). Recognized adapters get a one-tap "Load" button for their driver.
- "Open root manager" button when root isn't granted yet — best-effort launch of a known
  KernelSU-family manager package (currently tries `com.resukisu.resukisu`,
  `me.weishu.kernelsu`); falls back to a plain instruction if neither is installed under those
  exact names. Root itself still has to be granted manually from the manager's Superuser tab —
  that's how KernelSU works by design, this app can't and doesn't try to bypass it.

## Root access

Like any KernelSU/Magisk root app, the **first** time you use it you need to open your
manager's Superuser tab and grant root to Picters Modules Manager once. There is no supported
way for an app to self-grant or skip this — see the project memory
`project_picters_modules_manager_app.md` for what was actually checked before concluding that
(KernelSU's allowlist is deliberately user-controlled; LSPosed avoids the prompt entirely
differently, via Zygisk injection, not by bypassing the su grant).

## Building

Needs Flutter (stable channel) and an Android SDK. From this directory:

```sh
flutter pub get
flutter build apk --release   # hidden app, no launcher icon — what ships in the module
flutter build apk --debug     # adds a launcher icon (see android/app/src/debug/AndroidManifest.xml),
                               # for convenient sideloading while testing
```

## How this plugs into the kernel CI

`Kokuban_Kernel_CI_Center/ci_core_rs/src/build.rs`'s `build_oot_module_zip()` looks for a
release APK at `<cwd>/PictersModulesManager.apk` when it assembles the OOT-Modules module zip.
If found, it stages it at `system/app/PictersModulesManager/PictersModulesManager.apk` inside
the module's systemless overlay, so it registers as a genuine system app on the next boot after
the module is (re)installed — no `adb install` needed. If the file isn't there, that build step
is skipped (logged, not an error).

**CI doesn't build this Flutter app automatically yet** — that file has to be placed there by
hand (or by a CI step someone adds later; see the kernel repo's README for the current state of
that discussion). Until then: build the release APK here, copy it to
`Kokuban_Kernel_CI_Center/PictersModulesManager.apk`, then run the kernel CI build.

## Source layout

- `lib/main.dart` — app entry, Material 3 theme (seed `#6750A4`).
- `lib/home_screen.dart` — all UI: module list blocks, detected-adapters block, root-unavailable
  / empty states.
- `lib/module_repository.dart` — scans `/system/lib/modules` + `/proc/modules`, builds the
  insmod/rmmod scripts (including the cfg80211/mac80211 gating and stock-restore logic above).
- `lib/usb_devices.dart` — sysfs USB scan + the VID:PID → driver table.
- `lib/root_shell.dart` — runs scripts through `su` by piping them over stdin (not
  `su -c "<script>"` — multi-line scripts don't survive being inlined as a single `-c` argument).
- `lib/native_bridge.dart` + `android/.../MainActivity.kt` — the two things that need a real
  Android API instead of a root shell command: launching another app's UI, and requesting a
  pinned home-screen shortcut.
