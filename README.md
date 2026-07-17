# Picters Modules Manager

A dark Flutter app that manages the `picters-modules-pack` KernelSU/Magisk module over root —
the Wi-Fi injection stack and the other out-of-tree kernel drivers, straight from your phone.

Ships hidden (no launcher icon in release) as a system app inside the module; opened from the
module's Action button in your root manager, or via a pinned shortcut.

## Screens

- **Overview** — one switch flips the whole Wi-Fi stack between **Stock** (vendor `qca_cld3`) and
  **Inject** (our `cfg80211`/`mac80211` + injection). Switching to Inject asks for confirmation —
  stock Wi-Fi only comes back with a reboot. Plugged-in USB adapters load their driver with one
  tap; unrecognized devices fold into a panel showing their VID:PID.
- **Modules** — every staged `.ko`, grouped by type with a search field and an All / Loaded /
  Unloaded filter, each a row with a switch. Loading a driver pulls in its dependencies in order.

State polls live over a persistent root shell (pull to refresh). The **⋮** menu pins a
shortcut, opens the root manager, and shows the version. Self-updates from GitHub Releases,
independent of the module zip.

## Building

```sh
flutter pub get
flutter build apk --release   # hidden app shipped in the module
flutter build apk --debug     # adds a launcher icon for sideloading
```
