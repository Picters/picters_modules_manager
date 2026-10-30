import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'preview_environment.dart';

/// Small native-side helper that doesn't fit the root-shell model: requesting
/// a pinned home-screen shortcut (needs the real Android ShortcutManager API).
class NativeBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.picters.modulesmanager/system',
  );

  static const EventChannel _usbEvents = EventChannel(
    'com.picters.modulesmanager/system/usb_events',
  );

  /// Emits whenever a USB device is attached or detached (a system broadcast),
  /// so the UI can refresh the scan immediately instead of waiting for the next
  /// 1–5s poll tick. Purely an accelerator — the poll is still the safety net.
  static Stream<void> usbEvents() => PreviewEnvironment.enabled
      ? const Stream<void>.empty()
      : _usbEvents.receiveBroadcastStream().map((_) {});

  /// Asks the launcher to pin a shortcut for this app. Returns false if the
  /// launcher doesn't support it (or API < 26) — the caller should fall back
  /// to a manual "long-press app icon" style hint in that case, though on
  /// this project's actual target hardware it will always succeed/prompt.
  static Future<bool> requestPinShortcut() async {
    if (PreviewEnvironment.enabled) return false;
    try {
      return await _channel.invokeMethod<bool>('requestPinShortcut') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// In-memory policy codec only; these methods never write device settings.
  static Future<String> decodeThermalPolicy(Uint8List bytes) async {
    if (PreviewEnvironment.enabled || !Platform.isAndroid) {
      throw UnsupportedError('Thermal codec requires Android.');
    }
    final decoded = await _channel.invokeMapMethod<String, dynamic>(
      'decodeThermalPolicy',
      {'bytes': bytes},
    );
    final text = decoded?['text'];
    if (text is! String) {
      throw const FormatException('Missing decoded thermal policy.');
    }
    return text;
  }

  static Future<Uint8List> encodeThermalOverride(String text) async {
    if (PreviewEnvironment.enabled || !Platform.isAndroid) {
      throw UnsupportedError('Thermal codec requires Android.');
    }
    final bytes = await _channel.invokeMethod<Uint8List>(
      'encodeThermalPolicy',
      {'text': text, 'codec': 'legacy'},
    );
    if (bytes == null) {
      throw const FormatException('Missing encoded thermal policy.');
    }
    return bytes;
  }

  /// Opens GitHub in the user's browser. Downloads and flashing are manual.
  static Future<bool> openKernelReleases() async {
    if (PreviewEnvironment.enabled) {
      return openUrl(
        'https://github.com/Picters/android_kernel_xiaomi_sm8850-extra/releases/latest',
      );
    }
    try {
      return await _channel.invokeMethod<bool>('openKernelReleases') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens an HTTPS page only after a user action (for example the author card).
  static Future<bool> openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    if (PreviewEnvironment.enabled) {
      if (!Platform.isLinux) return false;
      try {
        final result = await Process.run('xdg-open', [uri.toString()]);
        return result.exitCode == 0;
      } on ProcessException {
        return false;
      }
    }
    try {
      return await _channel.invokeMethod<bool>('openUrl', {
            'url': uri.toString(),
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the installed root manager (KernelSU / APatch / Magisk) so the user
  /// can grant Superuser access without hunting for the app. Returns false if
  /// none of the known managers is installed.
  static Future<bool> openRootManager() async {
    if (PreviewEnvironment.enabled) return false;
    try {
      return await _channel.invokeMethod<bool>('openRootManager') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Fully restarts the app process — used on the root-denied screen, since a
  /// just-granted Superuser permission only takes on a clean start.
  static Future<void> restartApp() async {
    if (PreviewEnvironment.enabled) return;
    try {
      await _channel.invokeMethod<void>('restartApp');
    } on PlatformException {
      // ignored — nothing else to do if the platform can't relaunch us
    }
  }

  /// The app's private internal files dir (getFilesDir), so root can drop the
  /// debug archive somewhere FileProvider can then serve. Null if unavailable.
  static Future<String?> filesDir() async {
    if (PreviewEnvironment.enabled) return null;
    try {
      return await _channel.invokeMethod<String>('filesDir');
    } on PlatformException {
      return null;
    }
  }

  /// Hands [path] to the system share sheet (as a content:// URI via
  /// FileProvider). Returns false if the file is gone or no app handled it.
  static Future<bool> shareFile(String path) async {
    if (PreviewEnvironment.enabled) return false;
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
    if (PreviewEnvironment.enabled) return false;
    try {
      return await _channel.invokeMethod<bool>('saveFile', {
            'path': path,
            'name': name,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
