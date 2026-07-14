import 'package:flutter/material.dart';

import 'home_screen.dart';

void main() {
  runApp(const PictersModulesManagerApp());
}

class PictersModulesManagerApp extends StatelessWidget {
  const PictersModulesManagerApp({super.key});

  static const _seed = Color(0xFF6750A4);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Picters Modules Manager',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
