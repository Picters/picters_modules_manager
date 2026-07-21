import 'dart:async';

import 'package:flutter/services.dart';

/// Small native-side helper that doesn't fit the root-shell model: requesting
/// a pinned home-screen shortcut (needs the real Android ShortcutManager API).
class NativeBridge {
  static const MethodChannel _channel =
      MethodChannel('com.picters.modulesmanager/system');

  static const EventChannel _usbEvents =
      EventChannel('com.picters.modulesmanager/system/usb_events');

  /// Emits whenever a USB device is attached or detached (a system broadcast),
  /// so the UI can refresh the scan immediately instead of waiting for the next
  /// 1–5s poll tick. Purely an accelerator — the poll is still the safety net.
  static Stream<void> usbEvents() =>
      _usbEvents.receiveBroadcastStream().map((_) {});

  /// Asks the launcher to pin a shortcut for this app. Returns false if the
  /// launcher doesn't support it (or API < 26) — the caller should fall back
  /// to a manual "long-press app icon" style hint in that case, though on
  /// this project's actual target hardware it will always succeed/prompt.
  static Future<bool> requestPinShortcut() async {
    try {
      return await _channel.invokeMethod<bool>('requestPinShortcut') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the installed root manager (KernelSU / APatch / Magisk) so the user
  /// can grant Superuser access without hunting for the app. Returns false if
  /// none of the known managers is installed.
  static Future<bool> openRootManager() async {
    try {
      return await _channel.invokeMethod<bool>('openRootManager') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Fully restarts the app process — used on the root-denied screen, since a
  /// just-granted Superuser permission only takes on a clean start.
  static Future<void> restartApp() async {
    try {
      await _channel.invokeMethod<void>('restartApp');
    } on PlatformException {
      // ignored — nothing else to do if the platform can't relaunch us
    }
  }

  /// The app's private internal files dir (getFilesDir), so root can drop the
  /// debug archive somewhere FileProvider can then serve. Null if unavailable.
  static Future<String?> filesDir() async {
    try {
      return await _channel.invokeMethod<String>('filesDir');
    } on PlatformException {
      return null;
    }
  }

  /// Hands [path] to the system share sheet (as a content:// URI via
  /// FileProvider). Returns false if the file is gone or no app handled it.
  static Future<bool> shareFile(String path) async {
    try {
      return await _channel.invokeMethod<bool>('shareFile', {'path': path}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the SAF "save to…" dialog for [path], suggesting [name]. Returns
  /// true only once the file is copied to the chosen location.
  static Future<bool> saveFile(String path, String name) async {
    try {
      return await _channel
              .invokeMethod<bool>('saveFile', {'path': path, 'name': name}) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
