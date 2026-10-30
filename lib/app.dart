import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_shell.dart';
import 'theme.dart';

/// Shared UI. Mobile starts with real repositories; the desktop development
/// entry point explicitly injects its in-memory controller.
class PictersKernelManagerApp extends StatelessWidget {
  const PictersKernelManagerApp({
    super.key,
    this.controller,
    this.preview = false,
  });

  final AppController? controller;
  final bool preview;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: preview
        ? 'PictersKernel-Xiaomi17 · 1.4 Preview'
        : 'PictersKernel-Xiaomi17',
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.dark,
    theme: buildAppTheme(Brightness.light),
    darkTheme: buildAppTheme(Brightness.dark),
    home: AppShell(preview: preview, controller: controller),
  );
}
