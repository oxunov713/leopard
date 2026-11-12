import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'colors.dart';
import 'item_type.dart';

/// One SVG of the icon set (24 unit grid, `currentColor` strokes).
@immutable
class LeopardIconData {
  const LeopardIconData(this.name);

  /// File name without extension in `assets/icons/`.
  final String name;

  String get asset => 'assets/icons/$name.svg';
}

/// The icon set, copied from the approved design.
abstract final class LeopardIcons {
  static const LeopardIconData mark = LeopardIconData('mark');

  // Item types.
  static const LeopardIconData login = LeopardIconData('login');
  static const LeopardIconData card = LeopardIconData('card');
  static const LeopardIconData wifi = LeopardIconData('wifi');
  static const LeopardIconData apiKey = LeopardIconData('api_key');
  static const LeopardIconData sshKey = LeopardIconData('ssh_key');
  static const LeopardIconData secureNote = LeopardIconData('secure_note');

  // Interface.
  static const LeopardIconData lock = LeopardIconData('lock');
  static const LeopardIconData unlock = LeopardIconData('unlock');
  static const LeopardIconData search = LeopardIconData('search');
  static const LeopardIconData copy = LeopardIconData('copy');
  static const LeopardIconData eye = LeopardIconData('eye');
  static const LeopardIconData edit = LeopardIconData('edit');
  static const LeopardIconData more = LeopardIconData('more');
  static const LeopardIconData back = LeopardIconData('back');
  static const LeopardIconData close = LeopardIconData('close');
  static const LeopardIconData plus = LeopardIconData('plus');
  static const LeopardIconData generator = LeopardIconData('generator');
  static const LeopardIconData health = LeopardIconData('health');
  static const LeopardIconData shieldAlert = LeopardIconData('shield_alert');
  static const LeopardIconData scan = LeopardIconData('scan');
  static const LeopardIconData external = LeopardIconData('external');
  static const LeopardIconData clock = LeopardIconData('clock');
  static const LeopardIconData monitor = LeopardIconData('monitor');
  static const LeopardIconData vault = LeopardIconData('vault');

  /// Every icon, for tests and galleries.
  static const List<LeopardIconData> all = [
    mark,
    login,
    card,
    wifi,
    apiKey,
    sshKey,
    secureNote,
    lock,
    unlock,
    search,
    copy,
    eye,
    edit,
    more,
    back,
    close,
    plus,
    generator,
    health,
    shieldAlert,
    scan,
    external,
    clock,
    monitor,
    vault,
  ];
}

/// An icon of [LeopardIcons], tinted with [color] (default: the ambient
/// [IconTheme] colour).
class LeopardIcon extends StatelessWidget {
  const LeopardIcon(
    this.icon, {
    super.key,
    this.size = 22,
    this.color,
    this.semanticLabel,
  });

  final LeopardIconData icon;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? IconTheme.of(context).color ?? LeopardColors.text;
    return SvgPicture.asset(
      icon.asset,
      package: 'leopard_ui',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
      semanticsLabel: semanticLabel,
    );
  }
}

/// The brand mark: a keyhole inside a broken ring.
class LeopardMark extends StatelessWidget {
  const LeopardMark({
    super.key,
    this.size = 28,
    this.color = LeopardColors.primary,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      LeopardIcon(LeopardIcons.mark, size: size, color: color);
}

/// The tinted rounded square that holds an item type's icon.
class ItemTypeIcon extends StatelessWidget {
  const ItemTypeIcon(this.type, {super.key, this.size = 48, this.radius});

  final LeopardItemType type;

  /// Edge length of the square.
  final double size;

  /// Corner radius; defaults to 14 at size 48, scaled with [size].
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final tint = LeopardTypeTint.of(type);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint.background,
        borderRadius: BorderRadius.circular(radius ?? size * 14 / 48),
      ),
      child: LeopardIcon(type.icon, size: size * 0.54, color: tint.foreground),
    );
  }
}
