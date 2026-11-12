import 'package:leopard_core/leopard_core.dart';

import 'item_form.dart';

/// A field of an item that a keyboard shortcut copies.
typedef CopyField = ({String key, String label, String value});

String _viewLabel(ItemFieldSpec spec) =>
    spec.label.replaceAll(RegExp(r'\s*\(.*\)$'), '');

/// The field Ctrl/Cmd+C copies: the first secret one that is filled in
/// (the password of a login, the key of an API key, the card number, ...).
CopyField? primarySecretField(VaultItem item) {
  final values = itemFormValues(item);
  for (final spec in itemFieldSpecs[item.type] ?? const <ItemFieldSpec>[]) {
    final value = values[spec.key] ?? '';
    if (spec.secret && value.isNotEmpty) {
      return (key: spec.key, label: _viewLabel(spec), value: value);
    }
  }
  return null;
}

/// The field Ctrl/Cmd+B copies: the first plain one-line text that is filled
/// in (the username of a login, the network name of a Wi-Fi, ...).
CopyField? primaryPlainField(VaultItem item) {
  final values = itemFormValues(item);
  for (final spec in itemFieldSpecs[item.type] ?? const <ItemFieldSpec>[]) {
    final value = values[spec.key] ?? '';
    if (spec.key != 'title' &&
        spec.key != 'notes' &&
        !spec.secret &&
        !spec.multiline &&
        !spec.numeric &&
        spec.options == null &&
        value.isNotEmpty) {
      return (key: spec.key, label: _viewLabel(spec), value: value);
    }
  }
  return null;
}
