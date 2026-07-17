import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'theme.dart';

void main() => runApp(const PictersKernelManagerApp());

class PictersKernelManagerApp extends StatelessWidget {
  const PictersKernelManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Picters Modules Manager',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: const AppShell(),
    );
  }
}
