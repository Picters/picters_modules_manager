# Desktop interface preview

Run the same Flutter interface in a Linux window with `./preview-linux`, or:

```sh
/opt/flutter/bin/flutter pub get --offline
/opt/flutter/bin/flutter run -d linux --no-pub -t lib/main_preview.dart
```

The window opens at 480 × 900. Resize it to check other layouts. While Flutter
is attached, press `r` for hot reload, `R` to restart the demo, or `q` to quit.

Every desktop build uses an in-memory Xiaomi 17 demo. Wi-Fi modes, module
switches, adapter settings, performance profiles, frequency locking and boot
preferences can be tried without connecting a phone. Changes reset when the
app restarts. Release discovery is disabled; external links open only when
clicked.

The root facade and the persistent root session both reject commands in this
mode. Android native channels are disabled. The preview does not execute
`su`, write device settings, load drivers or install packages on the PC.

Android builds use the real device repositories by default. The explicit
`--dart-define=PICTERS_PREVIEW=true` build option enables the same isolated demo
on Android when needed for UI review.

The Performance page includes Clocks, Thermal and Charging. Thermal and charging
controls are demo-only until the device backend has been verified. Gaming and
frequency locking have separate Android implementations.

Production uses `lib/main.dart`, which does not import demo repositories.
The desktop tool uses `lib/main_preview.dart`; it refuses Android execution.
Android cannot enable preview via a Dart environment flag. Release ABI is arm64-v8a only.
