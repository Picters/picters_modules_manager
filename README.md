# Picters Modules Manager

A dark, root Flutter app that manages the `picters-modules-pack` KernelSU/Magisk module — the
Wi-Fi injection stack and other out-of-tree kernel drivers — from your phone. It toggles each
driver over root, switches Wi-Fi between **Stock** and **Inject**, and self-updates from GitHub
Releases. Ships hidden inside the module and opens from its Action button.

## Build

```sh
flutter pub get
flutter build apk --release   # hidden app shipped in the module
flutter build apk --debug     # adds a launcher icon for sideloading
```

## Credits

Root: **ReSukiSU / KernelSU** · Injection drivers: **aircrack-ng**, **morrownr**.
