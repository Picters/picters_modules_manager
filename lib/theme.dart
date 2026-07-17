import 'package:flutter/material.dart';

/// Fixed brand palette. The app no longer pulls colours from the device
/// wallpaper (Material You / dynamic_color has been removed): the look is the
/// same on every device and Android version. A calm blue accent with a teal
/// tertiary on cool-neutral surfaces; red is reserved for genuine errors.

const ColorScheme _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFF8AB4FF),
  onPrimary: Color(0xFF002E6E),
  primaryContainer: Color(0xFF1F4585),
  onPrimaryContainer: Color(0xFFD7E3FF),
  secondary: Color(0xFF9FC0FF),
  onSecondary: Color(0xFF002E6E),
  secondaryContainer: Color(0xFF283C5C),
  onSecondaryContainer: Color(0xFFD7E3FF),
  tertiary: Color(0xFF7FD0C4),
  onTertiary: Color(0xFF00382F),
  tertiaryContainer: Color(0xFF1E4E46),
  onTertiaryContainer: Color(0xFF9BEDDE),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
  errorContainer: Color(0xFF93000A),
  onErrorContainer: Color(0xFFFFDAD6),
  surface: Color(0xFF121316),
  onSurface: Color(0xFFE3E2E6),
  onSurfaceVariant: Color(0xFFAEB1BA),
  surfaceContainerLowest: Color(0xFF0D0E11),
  surfaceContainerLow: Color(0xFF191A1D),
  surfaceContainer: Color(0xFF1D1E21),
  surfaceContainerHigh: Color(0xFF27282B),
  surfaceContainerHighest: Color(0xFF323337),
  outline: Color(0xFF5D5F66),
  outlineVariant: Color(0xFF3A3C40),
  inverseSurface: Color(0xFFE3E2E6),
  onInverseSurface: Color(0xFF1B1B1D),
  inversePrimary: Color(0xFF2E5FA6),
);

const ColorScheme _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF2E5FA6),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFD7E3FF),
  onPrimaryContainer: Color(0xFF001A43),
  secondary: Color(0xFF41618E),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFD7E3FF),
  onSecondaryContainer: Color(0xFF001A43),
  tertiary: Color(0xFF1E6A5F),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFA6F2E4),
  onTertiaryContainer: Color(0xFF00201B),
  error: Color(0xFFBA1A1A),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFFDAD6),
  onErrorContainer: Color(0xFF410002),
  surface: Color(0xFFFBF9FD),
  onSurface: Color(0xFF1A1B1F),
  onSurfaceVariant: Color(0xFF44474F),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF3F3F8),
  surfaceContainer: Color(0xFFEDEEF3),
  surfaceContainerHigh: Color(0xFFE7E8ED),
  surfaceContainerHighest: Color(0xFFE1E2E7),
  outline: Color(0xFF74777F),
  outlineVariant: Color(0xFFC4C6CF),
  inverseSurface: Color(0xFF2F3033),
  onInverseSurface: Color(0xFFF1F0F4),
  inversePrimary: Color(0xFFA9C7FF),
);

/// Corner-radius tokens. Android 17 / Material 3 Expressive leans on large,
/// fully-rounded shapes — buttons and pills go full-stadium, cards and sheets
/// carry generous radii. Everything in the app pulls from these so the whole
/// UI reads as one rounded system.
class Corners {
  const Corners._();
  static const card = 26.0;
  static const hero = 30.0;
  static const field = 26.0;
  static const chip = 24.0;
  static const sheet = 30.0;
  static const dialog = 30.0;
}

ThemeData buildAppTheme(Brightness brightness) {
  final scheme = brightness == Brightness.dark ? _darkScheme : _lightScheme;

  // Two tiers, not three: body + app bar share the plain surface tone;
  // the nav bar and cards share the next tone step up. Distinct enough that
  // blocks read as separate from the page, without swinging all the way to
  // pure black.
  final baseBg = scheme.surface;
  final raisedBg = scheme.surfaceContainer;

  const cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(Corners.card)),
  );
  const stadium = StadiumBorder();

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: baseBg,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: baseBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: raisedBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 72,
      indicatorColor: scheme.secondaryContainer,
      indicatorShape: stadium,
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
      clipBehavior: Clip.antiAlias,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: stadium,
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: stadium,
        minimumSize: const Size(64, 48),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: stadium,
        minimumSize: const Size(48, 44),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(stadium),
        visualDensity: VisualDensity.standard,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.primary : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.onSurfaceVariant,
        ),
        iconColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.onSurfaceVariant,
        ),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.transparent : scheme.outline,
      ),
    ),
    dialogTheme: const DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Corners.dialog)),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Corners.sheet)),
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5)),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      insetPadding: EdgeInsets.fromLTRB(16, 5, 16, 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
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
