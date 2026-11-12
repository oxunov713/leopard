import 'package:flutter/material.dart';
import 'package:leopard_ui/leopard_ui.dart';

/// The one theme of the app: the shared Leopard dark theme, with the design's
/// own back and close icons on the app bar buttons.
ThemeData buildAppTheme() => leopardTheme(desktop: false).copyWith(
  actionIconTheme: ActionIconThemeData(
    backButtonIconBuilder: (context) => const LeopardIcon(LeopardIcons.back),
    closeButtonIconBuilder: (context) => const LeopardIcon(LeopardIcons.close),
  ),
);
