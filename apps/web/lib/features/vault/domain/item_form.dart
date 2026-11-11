import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';

/// One input of the item editor / one row of the item view.
final class ItemFieldSpec {
  const ItemFieldSpec(
    this.key,
    this.label, {
    this.secret = false,
    this.multiline = false,
    this.numeric = false,
    this.options,
  });

  final String key;
  final String label;

  /// Masked on screen, never learned by the keyboard.
  final bool secret;
  final bool multiline;
  final bool numeric;

  /// Fixed choices (Wi-Fi security); free text when `null`.
  final List<String>? options;
}

const ItemFieldSpec _title = ItemFieldSpec('title', 'Title');
const ItemFieldSpec _notes = ItemFieldSpec('notes', 'Notes', multiline: true);

/// The fields of each item type of crypto-spec §14.2, in display order.
///
/// A card has no field for its verification code (CVV/CVC): the schema
/// forbids storing it, so the app never asks for it.
const Map<String, List<ItemFieldSpec>> itemFieldSpecs = {
  LoginItem.typeName: [
    _title,
    ItemFieldSpec('username', 'Username'),
    ItemFieldSpec('password', 'Password', secret: true),
    ItemFieldSpec('urls', 'Websites (one per line)', multiline: true),
    ItemFieldSpec('totp', 'One-time code secret (optional)', secret: true),
    _notes,
  ],
  CardItem.typeName: [
    _title,
    ItemFieldSpec('holder', 'Cardholder'),
    ItemFieldSpec('number', 'Card number', secret: true, numeric: true),
    ItemFieldSpec('expMonth', 'Expiry month (1-12)', numeric: true),
    ItemFieldSpec('expYear', 'Expiry year (YYYY)', numeric: true),
    _notes,
  ],
  WifiItem.typeName: [
    _title,
    ItemFieldSpec('ssid', 'Network name (SSID)'),
    ItemFieldSpec('password', 'Password', secret: true),
    ItemFieldSpec(
      'security',
      'Security',
      options: [
        WifiItem.securityOpen,
        WifiItem.securityWep,
        WifiItem.securityWpa,
        WifiItem.securityWpa2,
        WifiItem.securityWpa3,
      ],
    ),
    _notes,
  ],
  ApiKeyItem.typeName: [
    _title,
    ItemFieldSpec('service', 'Service'),
    ItemFieldSpec('key', 'Key', secret: true),
    ItemFieldSpec('secret', 'Secret (optional)', secret: true),
    _notes,
  ],
  SshKeyItem.typeName: [
    _title,
    ItemFieldSpec('privateKey', 'Private key', secret: true, multiline: true),
    ItemFieldSpec('publicKey', 'Public key (optional)', multiline: true),
    ItemFieldSpec('passphrase', 'Passphrase (optional)', secret: true),
    _notes,
  ],
  SecureNoteItem.typeName: [
    _title,
    ItemFieldSpec('body', 'Note', secret: true, multiline: true),
  ],
};

/// The current values of [item], keyed like [itemFieldSpecs].
Map<String, String> itemFormValues(VaultItem item) => switch (item) {
  LoginItem() => {
    'title': item.title,
    'username': item.username,
    'password': item.password,
    'urls': item.urls.join('\n'),
    'totp': item.totp ?? '',
    'notes': item.notes,
  },
  CardItem() => {
    'title': item.title,
    'holder': item.holder,
    'number': item.number,
    'expMonth': '${item.expMonth}',
    'expYear': '${item.expYear}',
    'notes': item.notes,
  },
  WifiItem() => {
    'title': item.title,
    'ssid': item.ssid,
    'password': item.password,
    'security': item.security,
    'notes': item.notes,
  },
  ApiKeyItem() => {
    'title': item.title,
    'service': item.service,
    'key': item.key,
    'secret': item.secret ?? '',
    'notes': item.notes,
  },
  SshKeyItem() => {
    'title': item.title,
    'privateKey': item.privateKey,
    'publicKey': item.publicKey ?? '',
    'passphrase': item.passphrase ?? '',
    'notes': item.notes,
  },
  SecureNoteItem() => {'title': item.title, 'body': item.body},
  UnknownItem() => {'title': item.title},
};

/// Builds the item to save from the editor's [values].
///
/// For an edit pass the item being replaced as [original]: its creation time
/// and any members this app does not know are carried over (crypto-spec
/// §14.4 rule 4). `updatedAt` is always [now]. Secrets are taken exactly as
/// typed; only the title and other labels are trimmed.
///
/// Throws [ValidationFailure] with a message for the user.
VaultItem buildItem({
  required String type,
  required Map<String, String> values,
  required DateTime now,
  VaultItem? original,
}) {
  String raw(String key) => values[key] ?? '';
  String text(String key) => raw(key).trim();
  String? optional(String key) => raw(key).isEmpty ? null : raw(key);

  if (original != null && original.type != type) {
    throw const ValidationFailure('The type of an item cannot be changed.');
  }
  final title = text('title');
  if (title.isEmpty) {
    throw const ValidationFailure('Give the item a title.');
  }
  final createdAt = original?.createdAt ?? now;
  final extra = original?.extra ?? const <String, Object?>{};

  switch (type) {
    case LoginItem.typeName:
      return LoginItem(
        title: title,
        username: text('username'),
        password: raw('password'),
        urls: [
          for (final line in raw('urls').split('\n'))
            if (line.trim().isNotEmpty) line.trim(),
        ],
        notes: raw('notes'),
        totp: optional('totp')?.trim(),
        createdAt: createdAt,
        updatedAt: now,
        extra: extra,
      );
    case CardItem.typeName:
      final month = int.tryParse(text('expMonth'));
      final year = int.tryParse(text('expYear'));
      if (month == null || month < 1 || month > 12) {
        throw const ValidationFailure('The expiry month must be 1 to 12.');
      }
      if (year == null || year < 1000 || year > 9999) {
        throw const ValidationFailure('The expiry year must have four digits.');
      }
      if (text('number').isEmpty) {
        throw const ValidationFailure('Enter the card number.');
      }
      return CardItem(
        title: title,
        holder: text('holder'),
        number: text('number'),
        expMonth: month,
        expYear: year,
        notes: raw('notes'),
        createdAt: createdAt,
        updatedAt: now,
        extra: extra,
      );
    case WifiItem.typeName:
      if (text('ssid').isEmpty) {
        throw const ValidationFailure('Enter the network name.');
      }
      return WifiItem(
        title: title,
        ssid: text('ssid'),
        password: raw('password'),
        security: text('security').isEmpty
            ? WifiItem.securityWpa2
            : text('security'),
        notes: raw('notes'),
        createdAt: createdAt,
        updatedAt: now,
        extra: extra,
      );
    case ApiKeyItem.typeName:
      if (raw('key').isEmpty) {
        throw const ValidationFailure('Enter the key.');
      }
      return ApiKeyItem(
        title: title,
        service: text('service'),
        key: raw('key'),
        secret: optional('secret'),
        notes: raw('notes'),
        createdAt: createdAt,
        updatedAt: now,
        extra: extra,
      );
    case SshKeyItem.typeName:
      if (raw('privateKey').trim().isEmpty) {
        throw const ValidationFailure('Paste the private key.');
      }
      return SshKeyItem(
        title: title,
        privateKey: raw('privateKey'),
        publicKey: optional('publicKey')?.trim(),
        passphrase: optional('passphrase'),
        notes: raw('notes'),
        createdAt: createdAt,
        updatedAt: now,
        extra: extra,
      );
    case SecureNoteItem.typeName:
      return SecureNoteItem(
        title: title,
        body: raw('body'),
        createdAt: createdAt,
        updatedAt: now,
        extra: extra,
      );
    default:
      throw const ValidationFailure('This kind of item cannot be edited.');
  }
}
