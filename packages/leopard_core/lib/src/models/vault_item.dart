import 'dart:convert';
import 'dart:typed_data';

/// The item plaintext could not be understood: it is not UTF-8 JSON, is not
/// an object, or a field of a known item type is missing or has the wrong
/// type. Messages never contain field values.
final class ItemFormatException implements Exception {
  const ItemFormatException(this.message);

  /// Description of the problem, safe to log.
  final String message;

  @override
  String toString() => 'ItemFormatException: $message';
}

/// A decrypted vault item: the plaintext inside the AEAD of crypto-spec §4,
/// in the "Item plaintext schema v1" of §14.
///
/// Subclasses are a closed set, so a `switch` over an item is exhaustive.
/// Items are immutable; to edit one, build a new object with the same
/// [createdAt], a new [updatedAt] and the old [extra].
///
/// Secrets in items are Dart strings and cannot be wiped from memory; drop
/// every reference to decrypted items on lock.
sealed class VaultItem {
  VaultItem({
    required this.title,
    required DateTime createdAt,
    required DateTime updatedAt,
    Map<String, Object?> extra = const {},
  }) : createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc(),
       extra = Map.unmodifiable(extra);

  /// The schema version written as `"v"`.
  static const int schemaVersion = 1;

  /// Parses decrypted plaintext bytes.
  ///
  /// Returns an [UnknownItem] for an object whose `v` is not 1 or whose
  /// `type` this version does not know. Throws [ItemFormatException] if the
  /// bytes are not a UTF-8 JSON object or a v1 item of a known type is
  /// malformed.
  static VaultItem decode(List<int> plaintext) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(plaintext));
    } on FormatException {
      throw const ItemFormatException('item plaintext is not UTF-8 JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const ItemFormatException('item plaintext is not a JSON object');
    }
    return VaultItem.fromJson(json);
  }

  /// Parses a decoded JSON object. See [decode].
  static VaultItem fromJson(Map<String, Object?> json) {
    if (json['v'] != schemaVersion) {
      return UnknownItem(json);
    }
    final r = _Reader(json);
    return switch (json['type']) {
      LoginItem.typeName => LoginItem._fromJson(r),
      CardItem.typeName => CardItem._fromJson(r),
      WifiItem.typeName => WifiItem._fromJson(r),
      ApiKeyItem.typeName => ApiKeyItem._fromJson(r),
      SshKeyItem.typeName => SshKeyItem._fromJson(r),
      SecureNoteItem.typeName => SecureNoteItem._fromJson(r),
      _ => UnknownItem(json),
    };
  }

  /// The `type` discriminator.
  String get type;

  /// Display name of the item.
  final String title;

  /// When the item was first created (UTC). Stored inside the encrypted
  /// payload, so the server cannot see or forge it.
  final DateTime createdAt;

  /// When the item's content last changed (UTC). Password-age audits use
  /// this, not the server's `updated_at`.
  final DateTime updatedAt;

  /// Keys this version does not know, preserved verbatim so that saving an
  /// item written by a newer client does not lose data.
  final Map<String, Object?> extra;

  /// The password that password audits should look at, or `null` if this
  /// item type has none.
  String? get auditablePassword => null;

  /// The type-specific fields, in schema order.
  Map<String, Object?> _fields();

  /// The plaintext JSON object: `v`, `type`, `title`, the type-specific
  /// fields, `createdAt`, `updatedAt`, then unknown keys.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'v': schemaVersion,
      'type': type,
      'title': title,
      ..._fields(),
      'createdAt': formatItemTimestamp(createdAt),
      'updatedAt': formatItemTimestamp(updatedAt),
    };
    for (final entry in extra.entries) {
      json.putIfAbsent(entry.key, () => entry.value);
    }
    return json;
  }

  /// The plaintext bytes to encrypt: compact UTF-8 JSON of [toJson].
  ///
  /// The returned buffer holds secrets; wipe it after encrypting.
  Uint8List encode() => utf8.encode(jsonEncode(toJson()));

  @override
  String toString() => '$runtimeType(title: $title)';
}

/// A website or app login.
final class LoginItem extends VaultItem {
  LoginItem({
    required super.title,
    required this.username,
    required this.password,
    List<String> urls = const [],
    this.notes = '',
    this.totp,
    required super.createdAt,
    required super.updatedAt,
    super.extra,
  }) : urls = List.unmodifiable(urls);

  factory LoginItem._fromJson(_Reader r) => LoginItem(
    title: r.string('title'),
    username: r.string('username'),
    password: r.string('password'),
    urls: r.stringList('urls'),
    notes: r.string('notes'),
    totp: r.optionalString('totp'),
    createdAt: r.timestamp('createdAt'),
    updatedAt: r.timestamp('updatedAt'),
    extra: r.rest(),
  );

  static const String typeName = 'login';

  final String username;
  final String password;

  /// Sites this login belongs to. May be empty.
  final List<String> urls;

  final String notes;

  /// Optional TOTP seed for this login: an `otpauth://` URI or a bare
  /// Base32 secret.
  final String? totp;

  @override
  String get type => typeName;

  @override
  String? get auditablePassword => password;

  @override
  Map<String, Object?> _fields() => {
    'username': username,
    'password': password,
    'urls': urls,
    'notes': notes,
    'totp': ?totp,
  };
}

/// A payment card. There is deliberately **no** field for the card
/// verification code (CVV/CVC): it must not be stored.
final class CardItem extends VaultItem {
  CardItem({
    required super.title,
    required this.holder,
    required this.number,
    required this.expMonth,
    required this.expYear,
    this.notes = '',
    required super.createdAt,
    required super.updatedAt,
    Map<String, Object?> extra = const {},
  }) : super(extra: _withoutVerificationCodes(extra)) {
    if (expMonth < 1 || expMonth > 12) {
      throw ArgumentError.value(expMonth, 'expMonth', 'must be 1 to 12');
    }
    if (expYear < 1000 || expYear > 9999) {
      throw ArgumentError.value(expYear, 'expYear', 'must have four digits');
    }
  }

  factory CardItem._fromJson(_Reader r) {
    final expMonth = r.integer('expMonth');
    final expYear = r.integer('expYear');
    if (expMonth < 1 || expMonth > 12 || expYear < 1000 || expYear > 9999) {
      throw const ItemFormatException('card expiry out of range');
    }
    return CardItem(
      title: r.string('title'),
      holder: r.string('holder'),
      number: r.string('number'),
      expMonth: expMonth,
      expYear: expYear,
      notes: r.string('notes'),
      createdAt: r.timestamp('createdAt'),
      updatedAt: r.timestamp('updatedAt'),
      extra: r.rest(),
    );
  }

  static const String typeName = 'card';

  /// Keys that would hold a card verification code. They are dropped when a
  /// card is parsed or built, and never written.
  static const Set<String> forbiddenKeys = {
    'cvv',
    'cvv2',
    'cvc',
    'cvc2',
    'cid',
    'csc',
    'securityCode',
  };

  final String holder;

  /// The card number as entered (digits, optionally with spaces).
  final String number;

  /// Expiry month, 1 to 12.
  final int expMonth;

  /// Expiry year, four digits.
  final int expYear;

  final String notes;

  @override
  String get type => typeName;

  @override
  Map<String, Object?> _fields() => {
    'holder': holder,
    'number': number,
    'expMonth': expMonth,
    'expYear': expYear,
    'notes': notes,
  };

  static Map<String, Object?> _withoutVerificationCodes(
    Map<String, Object?> extra,
  ) => {
    for (final entry in extra.entries)
      if (!forbiddenKeys.contains(entry.key)) entry.key: entry.value,
  };
}

/// A Wi-Fi network.
final class WifiItem extends VaultItem {
  WifiItem({
    required super.title,
    required this.ssid,
    required this.password,
    this.security = securityWpa2,
    this.notes = '',
    required super.createdAt,
    required super.updatedAt,
    super.extra,
  });

  factory WifiItem._fromJson(_Reader r) => WifiItem(
    title: r.string('title'),
    ssid: r.string('ssid'),
    password: r.string('password'),
    security: r.string('security'),
    notes: r.string('notes'),
    createdAt: r.timestamp('createdAt'),
    updatedAt: r.timestamp('updatedAt'),
    extra: r.rest(),
  );

  static const String typeName = 'wifi';

  /// Well-known values of [security]. Other strings are preserved as is.
  static const String securityOpen = 'open';
  static const String securityWep = 'wep';
  static const String securityWpa = 'wpa';
  static const String securityWpa2 = 'wpa2';
  static const String securityWpa3 = 'wpa3';

  final String ssid;

  /// The network passphrase; empty for an open network.
  final String password;

  /// One of `open`, `wep`, `wpa`, `wpa2`, `wpa3`, or another string written
  /// by a newer client.
  final String security;

  final String notes;

  @override
  String get type => typeName;

  @override
  String? get auditablePassword => password.isEmpty ? null : password;

  @override
  Map<String, Object?> _fields() => {
    'ssid': ssid,
    'password': password,
    'security': security,
    'notes': notes,
  };
}

/// An API credential.
final class ApiKeyItem extends VaultItem {
  ApiKeyItem({
    required super.title,
    required this.service,
    required this.key,
    this.secret,
    this.notes = '',
    required super.createdAt,
    required super.updatedAt,
    super.extra,
  });

  factory ApiKeyItem._fromJson(_Reader r) => ApiKeyItem(
    title: r.string('title'),
    service: r.string('service'),
    key: r.string('key'),
    secret: r.optionalString('secret'),
    notes: r.string('notes'),
    createdAt: r.timestamp('createdAt'),
    updatedAt: r.timestamp('updatedAt'),
    extra: r.rest(),
  );

  static const String typeName = 'apiKey';

  /// The service the key is for.
  final String service;

  /// The key, token or key id.
  final String key;

  /// Optional second half, for services that issue a key id plus a secret.
  final String? secret;

  final String notes;

  @override
  String get type => typeName;

  @override
  Map<String, Object?> _fields() => {
    'service': service,
    'key': key,
    'secret': ?secret,
    'notes': notes,
  };
}

/// An SSH key pair.
final class SshKeyItem extends VaultItem {
  SshKeyItem({
    required super.title,
    required this.privateKey,
    this.publicKey,
    this.passphrase,
    this.notes = '',
    required super.createdAt,
    required super.updatedAt,
    super.extra,
  });

  factory SshKeyItem._fromJson(_Reader r) => SshKeyItem(
    title: r.string('title'),
    privateKey: r.string('privateKey'),
    publicKey: r.optionalString('publicKey'),
    passphrase: r.optionalString('passphrase'),
    notes: r.string('notes'),
    createdAt: r.timestamp('createdAt'),
    updatedAt: r.timestamp('updatedAt'),
    extra: r.rest(),
  );

  static const String typeName = 'sshKey';

  /// The private key file contents (for example OpenSSH or PEM text).
  final String privateKey;

  /// Optional public key line.
  final String? publicKey;

  /// Optional passphrase protecting [privateKey].
  final String? passphrase;

  final String notes;

  @override
  String get type => typeName;

  @override
  Map<String, Object?> _fields() => {
    'privateKey': privateKey,
    'publicKey': ?publicKey,
    'passphrase': ?passphrase,
    'notes': notes,
  };
}

/// Free-form encrypted text.
final class SecureNoteItem extends VaultItem {
  SecureNoteItem({
    required super.title,
    required this.body,
    required super.createdAt,
    required super.updatedAt,
    super.extra,
  });

  factory SecureNoteItem._fromJson(_Reader r) => SecureNoteItem(
    title: r.string('title'),
    body: r.string('body'),
    createdAt: r.timestamp('createdAt'),
    updatedAt: r.timestamp('updatedAt'),
    extra: r.rest(),
  );

  static const String typeName = 'secureNote';

  final String body;

  @override
  String get type => typeName;

  @override
  Map<String, Object?> _fields() => {'body': body};
}

/// An item this version cannot interpret: a schema version other than 1, an
/// unknown `type`, or a payload written before schema v1.
///
/// The whole JSON object is kept in [raw] and [toJson] returns it unchanged,
/// so the item survives a sync or re-encryption. Clients MUST NOT offer to
/// edit it; show it as "created by a newer version of Leopard".
final class UnknownItem extends VaultItem {
  UnknownItem(Map<String, Object?> raw)
    : raw = Map.unmodifiable(raw),
      super(
        title: raw['title'] is String ? raw['title']! as String : '',
        createdAt: _lenientTimestamp(raw['createdAt']),
        updatedAt: _lenientTimestamp(raw['updatedAt']),
      );

  /// The complete, uninterpreted JSON object.
  final Map<String, Object?> raw;

  /// The raw `type` value if it is a string, otherwise the empty string.
  @override
  String get type => raw['type'] is String ? raw['type']! as String : '';

  /// The raw `v` value if it is an integer.
  int? get version => raw['v'] is int ? raw['v']! as int : null;

  @override
  Map<String, Object?> _fields() => const {};

  @override
  Map<String, Object?> toJson() => raw;

  static DateTime _lenientTimestamp(Object? value) {
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null && parsed.isUtc) {
        return parsed;
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
}

/// Formats an item timestamp: RFC 3339, UTC, exactly millisecond precision,
/// for example `2026-11-11T10:00:05.123Z`. Finer precision is truncated so
/// the output is identical on the VM and on the web.
String formatItemTimestamp(DateTime time) {
  final t = time.toUtc();
  String pad(int value, int width) => value.toString().padLeft(width, '0');
  return '${pad(t.year, 4)}-${pad(t.month, 2)}-${pad(t.day, 2)}'
      'T${pad(t.hour, 2)}:${pad(t.minute, 2)}:${pad(t.second, 2)}'
      '.${pad(t.millisecond, 3)}Z';
}

/// Reads typed fields from an item object and tracks which keys were used,
/// so the remainder can be preserved as `extra`.
final class _Reader {
  _Reader(this._json);

  final Map<String, Object?> _json;
  final Set<String> _used = {'v', 'type'};

  String string(String key) {
    _used.add(key);
    final value = _json[key];
    if (value is String) {
      return value;
    }
    throw ItemFormatException('item field "$key" must be a string');
  }

  String? optionalString(String key) {
    _used.add(key);
    final value = _json[key];
    if (value == null || value is String) {
      return value as String?;
    }
    throw ItemFormatException('item field "$key" must be a string');
  }

  int integer(String key) {
    _used.add(key);
    final value = _json[key];
    if (value is int) {
      return value;
    }
    throw ItemFormatException('item field "$key" must be an integer');
  }

  List<String> stringList(String key) {
    _used.add(key);
    final value = _json[key];
    if (value is List<Object?> && value.every((e) => e is String)) {
      return value.cast<String>();
    }
    throw ItemFormatException('item field "$key" must be a list of strings');
  }

  DateTime timestamp(String key) {
    _used.add(key);
    final value = _json[key];
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      // A missing UTC offset parses as local time; require an explicit one.
      if (parsed != null && parsed.isUtc) {
        return parsed;
      }
    }
    throw ItemFormatException(
      'item field "$key" must be an RFC 3339 timestamp with a UTC offset',
    );
  }

  Map<String, Object?> rest() => {
    for (final entry in _json.entries)
      if (!_used.contains(entry.key)) entry.key: entry.value,
  };
}
