import 'package:flutter/services.dart';

/// Small native-side helpers that don't fit the root-shell model: launching
/// another app (needs a real Android Intent, not a shell command) and
/// requesting a pinned home-screen shortcut (ShortcutManager API).
class NativeBridge {
  static const MethodChannel _channel =
      MethodChannel('com.picters.modulesmanager/system');

  /// Tries a short list of known KernelSU-family manager packages and opens
  /// whichever one is installed. Returns the package name opened, or null if
  /// none of the guesses matched (there's no reliable way to know a rebranded
  /// manager's package name in general).
  static Future<String?> openRootManager() async {
    try {
      return await _channel.invokeMethod<String>('openRootManager');
    } on PlatformException {
      return null;
    }
  }

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
}
