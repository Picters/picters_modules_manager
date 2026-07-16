import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'theme.dart';

void main() => runApp(const PictersKernelManagerApp());

class PictersKernelManagerApp extends StatelessWidget {
  const PictersKernelManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return MaterialApp(
          title: 'Picters Kernel Manager',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.system,
          theme: buildAppTheme(lightDynamic, Brightness.light),
          darkTheme: buildAppTheme(darkDynamic, Brightness.dark),
          home: const AppShell(),
        );
      },
    );
  }
}
