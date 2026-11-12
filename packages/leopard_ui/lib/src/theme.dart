import 'package:flutter/material.dart';

import 'colors.dart';
import 'fonts.dart';

/// Style for anything secret or machine-readable: passwords, keys, codes.
const TextStyle leopardSecretTextStyle = TextStyle(
  fontFamily: LeopardFonts.mono,
  fontFamilyFallback: ['monospace'],
  fontWeight: FontWeight.w500,
  fontSize: 15,
  height: 1.35,
  letterSpacing: 0.4,
  color: LeopardColors.text,
);

TextStyle _body(double size, FontWeight weight, {double? height}) => TextStyle(
  fontFamily: LeopardFonts.body,
  fontSize: size,
  fontWeight: weight,
  height: height,
  color: LeopardColors.text,
);

TextStyle _heading(
  double size,
  FontWeight weight, {
  double letterSpacing = 0,
}) => TextStyle(
  fontFamily: LeopardFonts.heading,
  fontSize: size,
  fontWeight: weight,
  letterSpacing: letterSpacing,
  color: LeopardColors.text,
);

/// Material 3 dark theme of Leopard. [desktop] is the web variant: denser
/// and with smaller radii.
ThemeData leopardTheme({required bool desktop}) {
  const scheme = ColorScheme.dark(
    primary: LeopardColors.primary,
    onPrimary: LeopardColors.onPrimary,
    primaryContainer: LeopardColors.primaryContainer,
    onPrimaryContainer: LeopardColors.primary,
    secondary: LeopardColors.primary,
    onSecondary: LeopardColors.onPrimary,
    secondaryContainer: LeopardColors.primaryContainer,
    onSecondaryContainer: LeopardColors.primary,
    surface: LeopardColors.surface,
    onSurface: LeopardColors.text,
    onSurfaceVariant: LeopardColors.textMuted,
    surfaceContainerLowest: LeopardColors.background,
    surfaceContainerLow: LeopardColors.sidebar,
    surfaceContainer: LeopardColors.surface,
    surfaceContainerHigh: LeopardColors.surfaceHigh,
    surfaceContainerHighest: LeopardColors.surfaceHigh,
    error: LeopardColors.danger,
    onError: LeopardColors.onPrimary,
    outline: LeopardColors.outlineStrong,
    outlineVariant: LeopardColors.outline,
  );

  final cardRadius = BorderRadius.circular(desktop ? 16 : 20);
  final buttonRadius = BorderRadius.circular(desktop ? 10 : 28);
  final inputRadius = BorderRadius.circular(desktop ? 10 : 28);
  const chipRadius = BorderRadius.all(Radius.circular(10));
  final dialogRadius = BorderRadius.circular(desktop ? 16 : 24);
  final fabRadius = BorderRadius.circular(desktop ? 14 : 18);
  final buttonShape = RoundedRectangleBorder(borderRadius: buttonRadius);
  final buttonPadding = EdgeInsets.symmetric(
    horizontal: desktop ? 18 : 24,
    vertical: desktop ? 12 : 16,
  );
  final buttonSize = Size(0, desktop ? 40 : 52);
  final buttonText = TextStyle(
    fontFamily: LeopardFonts.body,
    fontSize: desktop ? 14 : 15,
    fontWeight: FontWeight.w600,
  );

  OutlineInputBorder inputBorder(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: inputRadius,
        borderSide: BorderSide(color: color, width: width),
      );

  final textTheme = TextTheme(
    displayLarge: _heading(44, FontWeight.w600, letterSpacing: -0.5),
    displayMedium: _heading(36, FontWeight.w600, letterSpacing: -0.5),
    displaySmall: _heading(30, FontWeight.w600, letterSpacing: -0.5),
    headlineLarge: _heading(28, FontWeight.w600, letterSpacing: -0.4),
    headlineMedium: _heading(24, FontWeight.w600, letterSpacing: -0.3),
    headlineSmall: _heading(20, FontWeight.w600, letterSpacing: -0.2),
    titleLarge: _heading(20, FontWeight.w600),
    titleMedium: _body(16, FontWeight.w600),
    titleSmall: _body(14, FontWeight.w600),
    bodyLarge: _body(16, FontWeight.w400, height: 1.5),
    bodyMedium: _body(14, FontWeight.w400, height: 1.5),
    bodySmall: _body(
      12,
      FontWeight.w400,
      height: 1.4,
    ).copyWith(color: LeopardColors.textMuted),
    labelLarge: _body(14, FontWeight.w600),
    labelMedium: _body(12, FontWeight.w500),
    labelSmall: _body(11, FontWeight.w500),
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: LeopardColors.background,
    canvasColor: LeopardColors.background,
    fontFamily: LeopardFonts.body,
    visualDensity: desktop ? VisualDensity.compact : VisualDensity.standard,
    splashFactory: InkRipple.splashFactory,
    dividerColor: LeopardColors.divider,
  );

  return base.copyWith(
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    iconTheme: const IconThemeData(color: LeopardColors.text),
    appBarTheme: AppBarTheme(
      backgroundColor: LeopardColors.background,
      foregroundColor: LeopardColors.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: _heading(22, FontWeight.w600, letterSpacing: -0.3),
    ),
    cardTheme: CardThemeData(
      color: LeopardColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: cardRadius,
        side: const BorderSide(color: LeopardColors.outline),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: LeopardColors.divider,
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: LeopardColors.primary,
        foregroundColor: LeopardColors.onPrimary,
        disabledBackgroundColor: LeopardColors.surfaceHigh,
        disabledForegroundColor: LeopardColors.textMuted,
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LeopardColors.text,
        disabledForegroundColor: LeopardColors.textMuted,
        side: const BorderSide(color: LeopardColors.outlineStrong),
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: LeopardColors.primary,
        disabledForegroundColor: LeopardColors.textMuted,
        minimumSize: Size(0, desktop ? 36 : 44),
        padding: buttonPadding,
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: LeopardColors.text),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: LeopardColors.surfaceHigh,
      isDense: desktop,
      contentPadding: EdgeInsets.symmetric(
        horizontal: desktop ? 14 : 20,
        vertical: desktop ? 12 : 16,
      ),
      hintStyle: const TextStyle(color: LeopardColors.textMuted),
      labelStyle: const TextStyle(color: LeopardColors.textMuted),
      floatingLabelStyle: const TextStyle(color: LeopardColors.primary),
      helperStyle: const TextStyle(color: LeopardColors.textMuted),
      errorStyle: const TextStyle(color: LeopardColors.danger),
      prefixIconColor: LeopardColors.textMuted,
      suffixIconColor: LeopardColors.textMuted,
      border: inputBorder(LeopardColors.outline),
      enabledBorder: inputBorder(LeopardColors.outline),
      disabledBorder: inputBorder(LeopardColors.divider),
      focusedBorder: inputBorder(LeopardColors.primary, 1.5),
      errorBorder: inputBorder(LeopardColors.danger),
      focusedErrorBorder: inputBorder(LeopardColors.danger, 1.5),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: LeopardColors.surface,
      selectedColor: LeopardColors.primaryContainer,
      disabledColor: LeopardColors.surface,
      checkmarkColor: LeopardColors.primary,
      side: const BorderSide(color: LeopardColors.outline),
      shape: const RoundedRectangleBorder(borderRadius: chipRadius),
      labelStyle: _body(13, FontWeight.w500),
      secondaryLabelStyle: _body(
        13,
        FontWeight.w500,
      ).copyWith(color: LeopardColors.primary),
      padding: EdgeInsets.symmetric(horizontal: desktop ? 6 : 8),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: LeopardColors.sidebar,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 72,
      indicatorColor: LeopardColors.primaryContainer,
      indicatorShape: const StadiumBorder(),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? LeopardColors.primary
              : LeopardColors.textMuted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: LeopardFonts.body,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? LeopardColors.text
              : LeopardColors.textMuted,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: LeopardColors.sidebar,
      indicatorColor: LeopardColors.primaryContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      selectedIconTheme: const IconThemeData(
        size: 20,
        color: LeopardColors.primary,
      ),
      unselectedIconTheme: const IconThemeData(
        size: 20,
        color: LeopardColors.textMuted,
      ),
      selectedLabelTextStyle: _body(13, FontWeight.w600),
      unselectedLabelTextStyle: _body(
        13,
        FontWeight.w500,
      ).copyWith(color: LeopardColors.textMuted),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: LeopardColors.primary,
      foregroundColor: LeopardColors.onPrimary,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(borderRadius: fabRadius),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: LeopardColors.surfaceHigh,
      contentTextStyle: _body(14, FontWeight.w500),
      actionTextColor: LeopardColors.primary,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(desktop ? 10 : 16),
        side: const BorderSide(color: LeopardColors.outline),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: LeopardColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: dialogRadius,
        side: const BorderSide(color: LeopardColors.outline),
      ),
      titleTextStyle: _heading(20, FontWeight.w600),
      contentTextStyle: _body(14, FontWeight.w400, height: 1.5),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: LeopardColors.textMuted,
      textColor: LeopardColors.text,
      titleTextStyle: _body(15, FontWeight.w500),
      subtitleTextStyle: _body(
        13,
        FontWeight.w400,
      ).copyWith(color: LeopardColors.textMuted),
      contentPadding: EdgeInsets.symmetric(horizontal: desktop ? 12 : 16),
      minVerticalPadding: desktop ? 6 : 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(desktop ? 10 : 16),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: LeopardColors.primary,
      linearTrackColor: LeopardColors.surfaceHigh,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: LeopardColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: LeopardColors.primary,
      selectionColor: LeopardColors.primary.withValues(alpha: 0.3),
      selectionHandleColor: LeopardColors.primary,
    ),
  );
}
