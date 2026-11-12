import 'package:flutter/material.dart';

/// Leopard's colours: near-black surfaces with a brass accent.
abstract final class LeopardColors {
  static const Color background = Color(0xFF0A0A0C);
  static const Color surface = Color(0xFF121216);
  static const Color surfaceHigh = Color(0xFF1A1A20);
  static const Color outline = Color(0xFF2C2C34);
  static const Color brass = Color(0xFFC6A15B);
  static const Color brassDim = Color(0xFF8F7440);
  static const Color onBrass = Color(0xFF14110A);
  static const Color text = Color(0xFFE9E6DF);
  static const Color textMuted = Color(0xFF9A978F);
  static const Color danger = Color(0xFFD9675B);
  static const Color ok = Color(0xFF7FB58A);
  static const Color warning = Color(0xFFD8A94A);
}

/// Text style for anything secret or machine-readable: passwords, keys,
/// codes. Monospace so that similar characters can be told apart. The font
/// is bundled (assets/fonts): nothing is fetched from a font CDN.
const TextStyle secretTextStyle = TextStyle(
  fontFamily: 'RobotoMono',
  fontFamilyFallback: ['Roboto'],
  fontSize: 15,
  height: 1.35,
  letterSpacing: 0.4,
  color: LeopardColors.text,
);

/// The only theme of the app. There is no light mode.
ThemeData buildLeopardTheme() {
  const scheme = ColorScheme.dark(
    primary: LeopardColors.brass,
    onPrimary: LeopardColors.onBrass,
    secondary: LeopardColors.brassDim,
    onSecondary: LeopardColors.onBrass,
    surface: LeopardColors.surface,
    onSurface: LeopardColors.text,
    error: LeopardColors.danger,
    onError: LeopardColors.onBrass,
    outline: LeopardColors.outline,
  );
  const radius = BorderRadius.all(Radius.circular(6));
  const shape = RoundedRectangleBorder(borderRadius: radius);
  final base = ThemeData(
    useMaterial3: true,
    // Bundled, and named explicitly so that every platform (including
    // macOS and iOS browsers, where Material would ask for a system font)
    // renders with the same local font.
    fontFamily: 'Roboto',
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: LeopardColors.background,
    splashFactory: InkRipple.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: LeopardColors.text,
      displayColor: LeopardColors.text,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: LeopardColors.background,
      foregroundColor: LeopardColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: LeopardColors.text,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: LeopardColors.outline,
      thickness: 1,
      space: 1,
    ),
    cardTheme: const CardThemeData(
      color: LeopardColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: LeopardColors.outline),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: LeopardColors.textMuted,
      textColor: LeopardColors.text,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: LeopardColors.surface,
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: LeopardColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: LeopardColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: LeopardColors.brass, width: 1.5),
      ),
      labelStyle: TextStyle(color: LeopardColors.textMuted),
      helperStyle: TextStyle(color: LeopardColors.textMuted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: LeopardColors.brass,
        foregroundColor: LeopardColors.onBrass,
        minimumSize: const Size.fromHeight(48),
        shape: shape,
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LeopardColors.brass,
        minimumSize: const Size.fromHeight(48),
        shape: shape,
        side: const BorderSide(color: LeopardColors.brassDim),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: LeopardColors.brass),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: LeopardColors.surface,
      selectedColor: LeopardColors.brassDim,
      side: const BorderSide(color: LeopardColors.outline),
      shape: shape,
      labelStyle: const TextStyle(color: LeopardColors.text),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: LeopardColors.surface,
      indicatorColor: LeopardColors.brassDim.withValues(alpha: 0.35),
      selectedIconTheme: const IconThemeData(color: LeopardColors.brass),
      unselectedIconTheme: const IconThemeData(color: LeopardColors.textMuted),
      selectedLabelTextStyle: const TextStyle(
        fontSize: 12,
        letterSpacing: 0.4,
        color: LeopardColors.text,
      ),
      unselectedLabelTextStyle: const TextStyle(
        fontSize: 12,
        letterSpacing: 0.4,
        color: LeopardColors.textMuted,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: LeopardColors.surface,
      indicatorColor: LeopardColors.brassDim.withValues(alpha: 0.35),
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 12, letterSpacing: 0.4),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: LeopardColors.brass,
      foregroundColor: LeopardColors.onBrass,
      shape: shape,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: LeopardColors.surfaceHigh,
      contentTextStyle: TextStyle(color: LeopardColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: LeopardColors.surfaceHigh,
      shape: shape,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: LeopardColors.brass,
    ),
    checkboxTheme: CheckboxThemeData(
      side: const BorderSide(color: LeopardColors.textMuted, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? LeopardColors.brass
            : Colors.transparent,
      ),
      checkColor: WidgetStateProperty.all(LeopardColors.onBrass),
    ),
  );
}
