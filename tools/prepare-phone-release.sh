#!/bin/sh
# Preparation only: print the eventual phone release commands; never build.
set -eu
release_app_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
printf 'No build started. Future phone release recipe:\n\n'
printf 'cd "%s"\n' "$release_app_root"
printf '%s\n' '/opt/flutter/bin/flutter build apk --release --target-platform=android-arm64 --target=lib/main.dart'
printf '\nExpected APK: %s/build/app/outputs/flutter-apk/app-release.apk\n' "$release_app_root"
printf '%s\n' 'Before delivery: verify arm64-v8a only, version 1.4.0+17, stable release certificate.'
printf '%s\n' 'Then copy the approved signed APK into CI assets and refresh its SHA-256 before packaging PictersKernelPack.'
printf '%s\n' 'Kernel and PictersKernelPack must use the same source snapshot, config and kernel release.'
