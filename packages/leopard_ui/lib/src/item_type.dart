import 'package:flutter/widgets.dart';

import 'colors.dart';
import 'icons.dart';

/// The six vault item types. [typeName] is the `type` string used by
/// `leopard_core` (`VaultItem.type`), so the two map one to one.
enum LeopardItemType {
  login('login', 'Login', LeopardIcons.login),
  card('card', 'Card', LeopardIcons.card),
  wifi('wifi', 'Wi-Fi', LeopardIcons.wifi),
  apiKey('apiKey', 'API key', LeopardIcons.apiKey),
  sshKey('sshKey', 'SSH key', LeopardIcons.sshKey),
  secureNote('secureNote', 'Secure note', LeopardIcons.secureNote);

  const LeopardItemType(this.typeName, this.label, this.icon);

  /// Same string as `VaultItem.type` in `leopard_core`.
  final String typeName;

  /// Human-readable name.
  final String label;

  final LeopardIconData icon;

  /// The type for a `VaultItem.type` string, or `null` for an unknown one.
  static LeopardItemType? fromTypeName(String typeName) {
    for (final type in values) {
      if (type.typeName == typeName) return type;
    }
    return null;
  }
}

/// Background and foreground colour of an item type's icon tile.
@immutable
class LeopardTypeTint {
  const LeopardTypeTint({required this.background, required this.foreground});

  final Color background;
  final Color foreground;

  static const LeopardTypeTint login = LeopardTypeTint(
    background: Color(0xFF2C1D16),
    foreground: LeopardColors.primary,
  );
  static const LeopardTypeTint card = LeopardTypeTint(
    background: Color(0xFF16212A),
    foreground: Color(0xFF7FB8E8),
  );
  static const LeopardTypeTint wifi = LeopardTypeTint(
    background: Color(0xFF172A22),
    foreground: Color(0xFF86C29A),
  );
  static const LeopardTypeTint apiKey = LeopardTypeTint(
    background: Color(0xFF241A2C),
    foreground: Color(0xFFC9A2E8),
  );
  static const LeopardTypeTint sshKey = LeopardTypeTint(
    background: Color(0xFF2A1C18),
    foreground: Color(0xFFE8957F),
  );
  static const LeopardTypeTint secureNote = LeopardTypeTint(
    background: Color(0xFF24231A),
    foreground: Color(0xFFE0D27A),
  );

  /// The tint of [type].
  static LeopardTypeTint of(LeopardItemType type) => switch (type) {
    LeopardItemType.login => login,
    LeopardItemType.card => card,
    LeopardItemType.wifi => wifi,
    LeopardItemType.apiKey => apiKey,
    LeopardItemType.sshKey => sshKey,
    LeopardItemType.secureNote => secureNote,
  };
}
