import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'preview_backend.dart';

/// Development-only entry point; never used by the phone release recipe.
void main() {
  if (!Platform.isLinux) {
    throw UnsupportedError('Desktop UI preview is Linux-only.');
  }
  runApp(
    PictersKernelManagerApp(
      preview: true,
      controller: createPreviewController(),
    ),
  );
}
