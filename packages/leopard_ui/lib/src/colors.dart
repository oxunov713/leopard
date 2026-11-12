import 'package:flutter/painting.dart';

/// Colour tokens of the approved design. There is no light mode.
abstract final class LeopardColors {
  static const Color background = Color(0xFF0E0E10);
  static const Color surface = Color(0xFF17171A);
  static const Color surfaceHigh = Color(0xFF1F1F23);
  static const Color sidebar = Color(0xFF121214);
  static const Color divider = Color(0xFF26262B);
  static const Color outline = Color(0xFF2E2E34);
  static const Color outlineStrong = Color(0xFF3A3A41);

  static const Color text = Color(0xFFECE8E1);
  static const Color textMuted = Color(0xFFA09C94);
  static const Color textSoft = Color(0xFFD6D2CA);

  /// The accent.
  static const Color primary = Color(0xFFE8743B);
  static const Color onPrimary = Color(0xFF1A0D06);
  static const Color primaryContainer = Color(0xFF3D2519);

  /// Icon tile behind the launcher mark.
  static const Color markTile = Color(0xFF17140F);

  static const Color ok = Color(0xFF86C29A);
  static const Color danger = Color(0xFFE5776B);
}
