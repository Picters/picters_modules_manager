import 'package:flutter/material.dart';

/// Strictly black / gray / white / red. No other hues anywhere in the app.
class AppColors {
  static const black = Color(0xFF000000);
  static const surface = Color(0xFF121212);
  static const surfaceHigh = Color(0xFF1C1C1E);
  static const surfaceGlass = Color(0xCC141414);
  static const outline = Color(0xFF2A2A2C);
  static const white = Color(0xFFF5F5F7);
  static const gray = Color(0xFF8A8A8E);
  static const grayDim = Color(0xFF5A5A5E);
  static const red = Color(0xFFFF453A);
  static const redDim = Color(0x22FF453A);
}

ThemeData buildAppTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.red,
    onPrimary: AppColors.white,
    secondary: AppColors.white,
    onSecondary: AppColors.black,
    error: AppColors.red,
    onError: AppColors.white,
    surface: AppColors.black,
    onSurface: AppColors.white,
    surfaceContainerLowest: AppColors.black,
    surfaceContainerLow: AppColors.surface,
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: AppColors.surfaceHigh,
    onSurfaceVariant: AppColors.gray,
    outline: AppColors.outline,
    outlineVariant: AppColors.outline,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.black,
    splashFactory: InkSparkle.splashFactory,
  );

  return base.copyWith(
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? AppColors.white : AppColors.gray),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? AppColors.red : AppColors.surfaceHigh),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? AppColors.red : AppColors.outline),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.white,
      displayColor: AppColors.white,
    ),
  );
}

/// A distinct, dark, rounded, floating error toast — deliberately NOT the old
/// white bottom snackbar. Red accent + icon.
void showError(BuildContext context, String message) {
  _showBanner(context, message, AppColors.red, Icons.error_outline);
}

void showInfo(BuildContext context, String message) {
  _showBanner(context, message, AppColors.white, Icons.check_circle_outline);
}

void _showBanner(
  BuildContext context,
  String message,
  Color accent,
  IconData icon,
) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.surfaceHigh,
        elevation: 0,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        duration: const Duration(seconds: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: accent.withValues(alpha: 0.7), width: 1.5),
        ),
        content: Row(
          children: [
            Icon(icon, color: accent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: AppColors.white,
                  fontSize: 14.5,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
}
