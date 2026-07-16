# Picters Kernel Manager

A dark Flutter app that controls the `nethunter-oot-modules` KernelSU/Magisk module over root —
the out-of-tree Wi-Fi injection stack and the other OOT kernel drivers, all unloaded by default.

Ships hidden (no launcher icon in release) as a system app inside the module; opened from the
module's Action button in your root manager, or via a pinned shortcut.

## Screens

- **Overview** — one switch flips the whole Wi-Fi stack between **STOCK** (vendor `qca_cld3`) and
  **NETHUNTER** (our `cfg80211`/`mac80211` + injection). Plugged-in USB adapters load their driver
  with one tap; unrecognized devices fold into a panel showing their VID:PID.
- **Modules** — every staged `.ko`, grouped by type with a search field, each a row with a switch.

State polls once a second over a persistent root shell (pull to refresh). The **⋮** menu pins a
shortcut, opens the root manager, and shows the version. Self-updates from GitHub Releases,
independent of the module zip.

## Building

```sh
flutter pub get
flutter build apk --release   # hidden app shipped in the module
flutter build apk --debug     # adds a launcher icon for sideloading
```
