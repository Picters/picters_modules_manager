## Manual release delivery

Picters Modules Manager is distributed inside the matching Android 16 / KMI 5 OOT modules pack. The app only reads release metadata and opens the latest kernel GitHub release in your browser. It never downloads updates, installs APKs/modules or flashes boot partitions.

Install the kernel and matching OOTMODULES pack from the same release.

Choose the kernel and OOTMODULES package from the same channel and release. Install and boot the kernel first, then install its OOT pack through KernelSU/Magisk and reboot. The APK is included as a system app. CPU/GPU frequency controls remain available.

# Picters Modules Manager

A dark, root Flutter app that manages the `picters-modules-pack` KernelSU/Magisk module — the
Wi-Fi injection stack and other out-of-tree kernel drivers — from your phone. In general it
toggles drivers over root, switches Wi-Fi between **Stock** and **Inject**, and hands a loaded
external adapter back to stock Android Settings as a normal managed station. Ships hidden inside
the module, links to GitHub Releases for manual updates, and opens from its Action button.

Because it ships as a system app, enable **Show system apps** in your KernelSU/Magisk manager to
find it and grant Superuser the first time.

## Performance

CPU/GPU frequency chips keep a fixed width. The Full GPU profile displays **Max** and requests the hardware maximum; a lower thermal limit is accepted without reporting a profile-switch error.

## Build

```sh
flutter pub get
flutter build apk --release   # hidden app shipped in the module
flutter build apk --debug     # adds a launcher icon for sideloading
```

## Credits

Root: **ReSukiSU / KernelSU** · Injection drivers: **aircrack-ng**, **morrownr**.
