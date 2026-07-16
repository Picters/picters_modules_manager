import 'package:flutter/material.dart';

/// Fallback seed when the device has no Material You palette to hand
/// (dynamicColor plugin returns null pre-Android-12, or on other platforms).
const Color _fallbackSeed = Color(0xFFFF453A);

ThemeData buildAppTheme(ColorScheme? dynamicScheme, Brightness brightness) {
  final scheme = dynamicScheme ??
      ColorScheme.fromSeed(seedColor: _fallbackSeed, brightness: brightness);

  // Two tiers, not three: body + app bar share the plain M3 surface tone;
  // the nav bar and cards share the next tone step up. Distinct enough that
  // blocks read as separate from the page, without swinging all the way to
  // pure black — this is standard M3 dark surface, not a custom hack.
  final baseBg = scheme.surface;
  final raisedBg = scheme.surfaceContainer;

  const cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(20)),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: baseBg,
    appBarTheme: AppBarTheme(
      backgroundColor: baseBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: raisedBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.secondaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: scheme.onSurface,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: raisedBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: cardShape,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5)),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      insetPadding: EdgeInsets.fromLTRB(16, 5, 16, 12),
    ),
  );
}

void showError(BuildContext context, String message) {
  _showBanner(context, message, isError: true);
}

void showInfo(BuildContext context, String message) {
  _showBanner(context, message, isError: false);
}

void _showBanner(BuildContext context, String message, {required bool isError}) {
  final scheme = Theme.of(context).colorScheme;
  final background = isError ? scheme.errorContainer : scheme.secondaryContainer;
  final foreground = isError ? scheme.onErrorContainer : scheme.onSecondaryContainer;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: background,
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: foreground,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: TextStyle(color: foreground)),
            ),
          ],
        ),
      ),
    );
}
