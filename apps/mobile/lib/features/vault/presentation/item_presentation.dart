import 'package:flutter/material.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_ui/leopard_ui.dart';

import '../domain/item_form.dart';

/// The tinted icon tile of an item type (a neutral tile for an unknown one).
Widget itemIcon(String type, {double size = 44}) {
  final known = LeopardItemType.fromTypeName(type);
  if (known != null) {
    return ItemTypeIcon(known, size: size);
  }
  return Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: LeopardColors.surfaceHigh,
      borderRadius: BorderRadius.circular(size * 14 / 48),
    ),
    child: Icon(
      Icons.help_outline,
      size: size * 0.5,
      color: LeopardColors.textMuted,
    ),
  );
}

/// A field label without its hint in brackets: "Password", not
/// "Password (optional)".
String fieldViewLabel(ItemFieldSpec spec) =>
    spec.label.replaceAll(RegExp(r'\s*\(.*\)$'), '');

/// The field that the copy button of a list row copies: the password if
/// there is one, otherwise the first other secret (never the one-time code
/// secret). `null` when the item has none.
({String label, String value})? copyableSecretOf(VaultItem item) {
  final values = itemFormValues(item);
  final specs = itemFieldSpecs[item.type] ?? const <ItemFieldSpec>[];
  ItemFieldSpec? pick;
  for (final spec in specs) {
    if (!spec.secret || (values[spec.key] ?? '').isEmpty) continue;
    if (spec.key == 'password') {
      pick = spec;
      break;
    }
    if (spec.key != 'totp') pick ??= spec;
  }
  if (pick == null) return null;
  return (label: fieldViewLabel(pick), value: values[pick.key]!);
}

/// "just now", "5 min ago", "2 days ago", or the date for anything older
/// than a month.
String relativeTime(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) {
    return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
  }
  if (diff.inDays < 31) {
    return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }
  final t = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}
