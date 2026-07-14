import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'theme.dart';

void main() => runApp(const PictersKernelManagerApp());

class PictersKernelManagerApp extends StatelessWidget {
  const PictersKernelManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Picters Kernel Manager',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const AppShell(),
    );
  }
}
