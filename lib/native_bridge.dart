import 'package:flutter/services.dart';

/// Small native-side helper that doesn't fit the root-shell model: requesting
/// a pinned home-screen shortcut (needs the real Android ShortcutManager API).
class NativeBridge {
  static const MethodChannel _channel =
      MethodChannel('com.picters.modulesmanager/system');

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
}
