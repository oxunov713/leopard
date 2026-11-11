import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

/// A decrypted item together with what the server knows about it.
final class VaultEntry extends Equatable {
  const VaultEntry({
    required this.id,
    required this.version,
    required this.item,
  });

  final String id;

  /// The server's version of this item; the `expected_version` of the next
  /// write.
  final int version;
  final VaultItem item;

  /// Whether the app can edit the item. Items written by a newer schema are
  /// kept verbatim and shown read-only (crypto-spec §14.4).
  bool get editable => item is! UnknownItem;

  // VaultItem has no value equality: two entries are the same when they are
  // the same version of the same item, or hold the very same object.
  @override
  List<Object?> get props => [id, version, identityHashCode(item)];
}

/// Display names of the item types, in menu order.
const Map<String, String> itemTypeLabels = {
  LoginItem.typeName: 'Login',
  CardItem.typeName: 'Card',
  WifiItem.typeName: 'Wi-Fi',
  ApiKeyItem.typeName: 'API key',
  SshKeyItem.typeName: 'SSH key',
  SecureNoteItem.typeName: 'Secure note',
};

String itemTypeLabel(String type) => itemTypeLabels[type] ?? 'Unsupported';

/// The line shown under the title in lists. Never a secret.
String entrySubtitle(VaultItem item) => switch (item) {
  LoginItem(:final username, :final urls) =>
    username.isNotEmpty ? username : (urls.isEmpty ? '' : urls.first),
  CardItem(:final number, :final holder) => _maskedCard(number, holder),
  WifiItem(:final ssid) => ssid,
  ApiKeyItem(:final service) => service,
  SshKeyItem(:final publicKey) => _sshKeyKind(publicKey),
  SecureNoteItem() => '',
  UnknownItem() => 'Created by a newer version of Leopard',
};

String _maskedCard(String number, String holder) {
  final digits = number.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 4) {
    return holder;
  }
  return '•••• ${digits.substring(digits.length - 4)}';
}

String _sshKeyKind(String? publicKey) {
  if (publicKey == null || publicKey.isEmpty) {
    return '';
  }
  return publicKey.trim().split(RegExp(r'\s+')).first;
}

/// Case-insensitive search over the non-secret fields of an item.
bool entryMatches(VaultEntry entry, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return true;
  }
  final item = entry.item;
  final haystack = <String>[
    item.title,
    ...switch (item) {
      LoginItem(:final username, :final urls) => [username, ...urls],
      CardItem(:final holder) => [holder],
      WifiItem(:final ssid) => [ssid],
      ApiKeyItem(:final service) => [service],
      SshKeyItem() || SecureNoteItem() || UnknownItem() => const <String>[],
    },
  ];
  return haystack.any((text) => text.toLowerCase().contains(needle));
}

int compareEntries(VaultEntry a, VaultEntry b) {
  final byTitle = a.item.title.toLowerCase().compareTo(
    b.item.title.toLowerCase(),
  );
  return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
}
