import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:leopard_ui/leopard_ui.dart';

/// Amber for "attention, not an error". The shared palette has none.
const Color warningColor = Color(0xFFE0B25A);

/// Whether the user's keyboard has a Command key rather than Ctrl.
bool get usesCommandKey =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// "Ctrl K" or "Cmd K", for the hints next to buttons.
String shortcutLabel(String key) => '${usesCommandKey ? 'Cmd' : 'Ctrl'} $key';

/// Space Grotesk, for titles and the wordmark.
TextStyle headingStyle(double size, {double letterSpacing = 0}) => TextStyle(
  fontFamily: LeopardFonts.heading,
  fontSize: size,
  fontWeight: FontWeight.w600,
  letterSpacing: letterSpacing,
  color: LeopardColors.text,
);

/// Window widths at which the layout changes.
abstract final class HomeBreakpoints {
  /// From here on the sidebar is shown in full.
  static const double sidebar = 1100;

  /// From here on there are two panes and a rail; below it one pane at a
  /// time and a bar at the bottom.
  static const double rail = 700;
}

/// A keyboard hint: the label of a key combination in a small outline.
class Kbd extends StatelessWidget {
  const Kbd(
    this.label, {
    super.key,
    this.color = LeopardColors.textMuted,
    this.outlined = true,
  });

  final String label;
  final Color color;
  final bool outlined;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: outlined ? 6 : 0, vertical: 2),
    decoration: outlined
        ? BoxDecoration(
            border: Border.all(color: LeopardColors.outlineStrong),
            borderRadius: BorderRadius.circular(5),
          )
        : null,
    child: Text(
      label,
      style: TextStyle(
        fontFamily: LeopardFonts.body,
        fontSize: 11,
        height: 1.2,
        color: color,
      ),
    ),
  );
}

/// A bordered surface card.
class CardPanel extends StatelessWidget {
  const CardPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 16,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  // A Material, so that list tiles and ink effects inside can paint.
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Material(
      color: LeopardColors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: const BorderSide(color: LeopardColors.divider),
      ),
      child: Padding(padding: padding, child: child),
    ),
  );
}

/// The bar across the top of the pages that are open without a login: mark,
/// wordmark and one optional action on the right.
class PublicTopBar extends StatelessWidget {
  const PublicTopBar({super.key, this.trailing});

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Container(
      height: 72,
      padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 40),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: LeopardColors.surfaceHigh)),
      ),
      child: Row(
        children: [
          const LeopardMark(size: 28),
          const SizedBox(width: 12),
          Text('Leopard', style: headingStyle(18)),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// A page without the vault chrome: top bar plus [child].
class PublicPage extends StatelessWidget {
  const PublicPage({super.key, required this.child, this.action});

  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          PublicTopBar(trailing: action),
          Expanded(child: child),
        ],
      ),
    ),
  );
}
