import 'dart:io';

/// Desktop processes cannot access phone control interfaces. The mobile release
/// cannot enable desktop preview through a Dart environment flag.
abstract final class PreviewEnvironment {
  static bool get enabled => !Platform.isAndroid;
}
