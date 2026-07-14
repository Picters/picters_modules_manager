# Picters Kernel Manager

A dark, minimal Flutter companion app for the `nethunter-oot-modules` KernelSU/Magisk module
built by [Kokuban_Kernel_CI_Center](../Kokuban_Kernel_CI_Center). It controls the out-of-tree
Wi-Fi injection and other OOT kernel drivers over root — everything unloaded by default.

The app package is still `com.picters.modulesmanager` (so the module's Action button and the
system-app install path keep working); only the display name is **Picters Kernel Manager**, with
a dark **PKM** monogram icon. It has **no launcher icon** in release builds by design — it's
opened via the module's Action button in your KernelSU/Magisk manager, or you can pin a shortcut
from the app's own app bar.

## Layout — two screens

- **Обзор (Overview)** — a hero card that switches the whole Wi-Fi stack between **STOCK**
  (vendor `qca_cld3`, internal Wi-Fi) and **NETHUNTER** (our kernel `cfg80211`/`mac80211`,
  injection). One switch: on → tears down vendor Wi-Fi and loads our stack; off → unwinds our
  stack and best-effort restores stock (verified against `/proc/modules`, with an honest
  "reboot to restore" message if it can't). Plugged-in USB adapters are listed here with a
  one-tap load for the driver they need.
- **Модули (Modules)** — every individual `.ko` staged by the module, grouped into Wi-Fi stack
  and other drivers, each a minimalist row with a switch, for deep manual control.

## Behaviour notes

- **Live**: a persistent root shell polls the system state once a second while the app is
  foreground, so module/adapter state updates on its own without a refresh button. Pull down to
  force a refresh (with iOS-style overscroll).
- **Colours**: strictly black / gray / white / red. NetHunter-active and errors are the only red
  accents.
- **cfg80211/mac80211** are driven together by the Overview mode switch; loading an individual
  adapter on the Modules tab while the stack is off surfaces a red "enable … first" error rather
  than silently cascading.
- **USB VID:PID table** is sourced from the `supported-device-IDs` files of the exact driver
  forks this project ships (aircrack-ng/rtl8812au, aircrack-ng/rtl8188eus, morrownr/8814au,
  morrownr/88x2bu-20210702).

## Root access

Like any KernelSU/Magisk root app, the first time you use it you grant root once from your
manager's Superuser tab (the app has an "Open root manager" button to jump there). There is no
supported way for an app to self-grant — see the project memory
`project_picters_modules_manager_app.md` for what was checked before concluding that.

## Building

```sh
flutter pub get
flutter build apk --release   # hidden app — what ships in the module
flutter build apk --debug     # adds a launcher icon (debug manifest) for easy sideloading
```

The PKM icon is generated from `PKM` text via a small Java (Graphics2D) renderer — see the
project memory for how to regenerate it if the branding changes.

## How this plugs into the kernel CI

`Kokuban_Kernel_CI_Center/ci_core_rs/src/build.rs`'s `build_oot_module_zip()` looks for a
release APK at `<cwd>/PictersModulesManager.apk`; if it's not there it best-effort runs
`gh release download --repo Picters/picters_modules_manager --pattern '*.apk'`. Either way the
APK is staged at `system/app/PictersModulesManager/PictersModulesManager.apk` in the module's
systemless overlay, so it registers as a system app on the next boot — no `adb install`. Never
built from source in the kernel CI (a Flutter/Gradle problem can't break a kernel build). Ship a
new version with `gh release create vX.Y.Z PictersModulesManager.apk --repo Picters/picters_modules_manager`.

## Source layout

- `lib/main.dart` / `lib/app_shell.dart` — app entry, dark theme, two-tab frosted nav shell,
  root-denied / checking states.
- `lib/overview_screen.dart` — hero Wi-Fi mode card + plugged-in adapters.
- `lib/modules_screen.dart` — all `.ko` grouped, minimalist toggles.
- `lib/app_controller.dart` — single source of truth: 1s live poll, root status, all actions.
- `lib/module_repository.dart` — combined scan (one `su` round-trip) + mode-switch / toggle
  script builders.
- `lib/module_info.dart` — models (`ModuleInfo`, `WifiMode`, `SystemState`).
- `lib/usb_devices.dart` — VID:PID → driver table + sysfs parsing.
- `lib/root_shell.dart` — persistent `su` session (one long-lived shell, marker-framed commands).
- `lib/native_bridge.dart` + `android/.../MainActivity.kt` — launch the root manager, pin a
  home-screen shortcut.
- `lib/theme.dart` / `lib/widgets.dart` — palette, error/info banners, shared card widgets.
