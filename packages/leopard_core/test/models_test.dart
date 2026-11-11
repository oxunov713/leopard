import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:test/test.dart';

final created = DateTime.utc(2026, 11, 11, 10, 0, 5, 123);
final updated = DateTime.utc(2026, 11, 12, 8, 30);

final throwsItemFormat = throwsA(isA<ItemFormatException>());

List<VaultItem> sampleItems() => [
  LoginItem(
    title: 'Example',
    username: 'aziz',
    password: 'correct horse battery staple',
    urls: const ['https://example.com', 'https://login.example.com'],
    notes: 'line 1\nline 2 — ünïcödé ✓',
    totp: 'otpauth://totp/Example:aziz?secret=JBSWY3DPEHPK3PXP',
    createdAt: created,
    updatedAt: updated,
  ),
  LoginItem(
    title: 'No TOTP',
    username: '',
    password: '',
    createdAt: created,
    updatedAt: updated,
  ),
  CardItem(
    title: 'Visa',
    holder: 'A. Example',
    number: '4111 1111 1111 1111',
    expMonth: 9,
    expYear: 2031,
    notes: '',
    createdAt: created,
    updatedAt: updated,
  ),
  WifiItem(
    title: 'Home',
    ssid: 'leopard-5g',
    password: 'hunter2hunter2',
    security: WifiItem.securityWpa3,
    createdAt: created,
    updatedAt: updated,
  ),
  ApiKeyItem(
    title: 'CI token',
    service: 'GitHub',
    key: 'ghp_example',
    createdAt: created,
    updatedAt: updated,
  ),
  ApiKeyItem(
    title: 'Object storage',
    service: 'S3',
    key: 'AKIAEXAMPLE',
    secret: 'c2VjcmV0',
    notes: 'read-only',
    createdAt: created,
    updatedAt: updated,
  ),
  SshKeyItem(
    title: 'Laptop',
    privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END-----\n',
    publicKey: 'ssh-ed25519 AAAAC3Nza example',
    passphrase: 'p',
    createdAt: created,
    updatedAt: updated,
  ),
  SshKeyItem(
    title: 'Bare',
    privateKey: 'k',
    createdAt: created,
    updatedAt: updated,
  ),
  SecureNoteItem(
    title: 'Note',
    body: '{"not":"parsed"}',
    createdAt: created,
    updatedAt: updated,
  ),
];

void main() {
  group('schema v1 JSON', () {
    test('exact layout of a login', () {
      expect(
        jsonEncode(sampleItems().first.toJson()),
        '''
{"v":1,"type":"login","title":"Example","username":"aziz","password":"correct horse battery staple","urls":["https://example.com","https://login.example.com"],"notes":"line 1\\nline 2 — ünïcödé ✓","totp":"otpauth://totp/Example:aziz?secret=JBSWY3DPEHPK3PXP","createdAt":"2026-11-11T10:00:05.123Z","updatedAt":"2026-11-12T08:30:00.000Z"}'''
            .trim(),
      );
    });

    test('exact key sets, including omitted optional fields', () {
      const common = ['v', 'type', 'title'];
      const tail = ['createdAt', 'updatedAt'];
      final expected = <List<String>>[
        [...common, 'username', 'password', 'urls', 'notes', 'totp', ...tail],
        [...common, 'username', 'password', 'urls', 'notes', ...tail],
        [
          ...common,
          'holder',
          'number',
          'expMonth',
          'expYear',
          'notes',
          ...tail,
        ],
        [...common, 'ssid', 'password', 'security', 'notes', ...tail],
        [...common, 'service', 'key', 'notes', ...tail],
        [...common, 'service', 'key', 'secret', 'notes', ...tail],
        [...common, 'privateKey', 'publicKey', 'passphrase', 'notes', ...tail],
        [...common, 'privateKey', 'notes', ...tail],
        [...common, 'body', ...tail],
      ];
      final items = sampleItems();
      expect(items, hasLength(expected.length));
      for (var i = 0; i < items.length; i++) {
        expect(items[i].toJson().keys.toList(), expected[i], reason: '$i');
        expect(items[i].toJson()['v'], 1);
      }
    });

    test('type discriminators', () {
      expect(sampleItems().map((i) => i.type).toSet(), {
        'login',
        'card',
        'wifi',
        'apiKey',
        'sshKey',
        'secureNote',
      });
    });

    test('a card has no CVV field and never writes one', () {
      final card = CardItem(
        title: 'Visa',
        holder: 'A',
        number: '4111111111111111',
        expMonth: 1,
        expYear: 2030,
        createdAt: created,
        updatedAt: updated,
        extra: const {'cvv': '123', 'cvc': '123', 'color': 'blue'},
      );
      final json = card.toJson();
      for (final key in CardItem.forbiddenKeys) {
        expect(json.containsKey(key), isFalse, reason: key);
      }
      expect(json['color'], 'blue');

      // A payload from a misbehaving client: the code is dropped on read.
      final parsed = VaultItem.fromJson({
        ...json,
        'cvv': '999',
        'securityCode': '999',
      });
      expect(parsed, isA<CardItem>());
      expect(parsed.extra.keys, ['color']);
      expect(jsonEncode(parsed.toJson()), isNot(contains('999')));
    });

    test('card expiry is validated', () {
      CardItem card(int month, int year) => CardItem(
        title: 't',
        holder: 'h',
        number: 'n',
        expMonth: month,
        expYear: year,
        createdAt: created,
        updatedAt: updated,
      );
      expect(() => card(0, 2030), throwsArgumentError);
      expect(() => card(13, 2030), throwsArgumentError);
      expect(() => card(12, 30), throwsArgumentError);
      final json = card(12, 2030).toJson();
      expect(
        () => VaultItem.fromJson({...json, 'expMonth': 13}),
        throwsItemFormat,
      );
      expect(
        () => VaultItem.fromJson({...json, 'expYear': 99}),
        throwsItemFormat,
      );
      expect(
        () => VaultItem.fromJson({...json, 'expMonth': '12'}),
        throwsItemFormat,
      );
    });
  });

  group('round-trip', () {
    test('every item type survives encode and decode', () {
      for (final item in sampleItems()) {
        final decoded = VaultItem.decode(item.encode());
        expect(decoded.runtimeType, item.runtimeType);
        expect(decoded.toJson(), item.toJson());
        expect(decoded.createdAt, created);
        expect(decoded.updatedAt, updated);
        expect(decoded.createdAt.isUtc, isTrue);
        // Byte-stable: encoding the decoded item gives the same bytes.
        expect(decoded.encode(), item.encode());
      }
    });

    test('every item type survives real encryption', () async {
      final crypto = LeopardCrypto(cryptography: DartCryptography());
      final itemKey = await crypto.deriveItemKey(crypto.generateVaultKey());
      for (final item in sampleItems()) {
        final id = newUuid();
        final sealed = await crypto.encryptItem(
          itemKey: itemKey,
          itemId: id,
          version: 1,
          plaintext: item.encode(),
        );
        final opened = await crypto.openItem(
          itemKey: itemKey,
          nonce: sealed.nonce,
          itemId: id,
          version: 1,
          ciphertext: sealed.ciphertext,
        );
        expect(VaultItem.decode(opened).toJson(), item.toJson());
      }
    });

    test('typed fields come back', () {
      final login = VaultItem.decode(sampleItems().first.encode()) as LoginItem;
      expect(login.title, 'Example');
      expect(login.username, 'aziz');
      expect(login.password, 'correct horse battery staple');
      expect(login.urls, ['https://example.com', 'https://login.example.com']);
      expect(login.totp, startsWith('otpauth://'));
      final card = VaultItem.decode(sampleItems()[2].encode()) as CardItem;
      expect(card.expMonth, 9);
      expect(card.expYear, 2031);
    });

    test('a switch over the sealed hierarchy is exhaustive', () {
      String describe(VaultItem item) => switch (item) {
        LoginItem() => 'login',
        CardItem() => 'card',
        WifiItem() => 'wifi',
        ApiKeyItem() => 'apiKey',
        SshKeyItem() => 'sshKey',
        SecureNoteItem() => 'secureNote',
        UnknownItem() => 'unknown',
      };
      for (final item in sampleItems()) {
        expect(describe(item), item.type);
      }
    });
  });

  group('timestamps', () {
    test('are written as UTC with millisecond precision', () {
      expect(
        formatItemTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)),
        '2026-01-02T03:04:05.000Z',
      );
      expect(
        formatItemTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 789)),
        '2026-01-02T03:04:05.006Z',
      );
      expect(
        formatItemTimestamp(DateTime.utc(987, 12, 31, 23, 59, 59, 999)),
        '0987-12-31T23:59:59.999Z',
      );
    });

    test('local times are converted to UTC', () {
      final local = DateTime(2026, 6, 1, 12);
      final note = SecureNoteItem(
        title: 't',
        body: 'b',
        createdAt: local,
        updatedAt: local,
      );
      expect(note.createdAt.isUtc, isTrue);
      expect(note.createdAt.isAtSameMomentAs(local), isTrue);
      expect(note.toJson()['createdAt'], formatItemTimestamp(local.toUtc()));
    });

    test('offsets and finer precision are accepted on read', () {
      final json = sampleItems().last.toJson();
      final parsed = VaultItem.fromJson({
        ...json,
        'createdAt': '2026-11-11T15:00:05.123456+05:00',
      });
      expect(
        parsed.createdAt.isAtSameMomentAs(
          DateTime.utc(2026, 11, 11, 10, 0, 5, 123, 456),
        ),
        isTrue,
      );
      expect(parsed.toJson()['createdAt'], '2026-11-11T10:00:05.123Z');
    });

    test('timestamps without an offset, or malformed, are rejected', () {
      final json = sampleItems().last.toJson();
      for (final bad in <Object?>[
        '2026-11-11T10:00:05',
        'yesterday',
        '',
        1762855205,
        null,
      ]) {
        expect(
          () => VaultItem.fromJson({...json, 'updatedAt': bad}),
          throwsItemFormat,
          reason: '$bad',
        );
      }
    });
  });

  group('forward compatibility', () {
    test('unknown keys of a known type are preserved on re-save', () {
      final json = {
        ...sampleItems().first.toJson(),
        'favorite': true,
        'tags': ['work', 'x'],
        'custom': {'a': 1},
      };
      final item = VaultItem.fromJson(json);
      expect(item, isA<LoginItem>());
      expect(item.extra, {
        'favorite': true,
        'tags': ['work', 'x'],
        'custom': {'a': 1},
      });
      expect(item.toJson(), json);
      expect(VaultItem.decode(item.encode()).toJson(), json);
    });

    test('extra cannot override a schema field', () {
      final note = SecureNoteItem(
        title: 'real',
        body: 'real body',
        createdAt: created,
        updatedAt: updated,
        extra: const {'title': 'fake', 'v': 2, 'type': 'login', 'x': 1},
      );
      final json = note.toJson();
      expect(json['title'], 'real');
      expect(json['v'], 1);
      expect(json['type'], 'secureNote');
      expect(json['x'], 1);
    });

    test('an unknown type is kept verbatim as UnknownItem', () {
      final json = <String, Object?>{
        'v': 1,
        'type': 'passkey',
        'title': 'Future thing',
        'credentialId': 'abc',
        'createdAt': '2027-01-01T00:00:00.000Z',
        'updatedAt': '2027-01-02T00:00:00.000Z',
      };
      final item = VaultItem.fromJson(json);
      expect(item, isA<UnknownItem>());
      expect(item.type, 'passkey');
      expect(item.title, 'Future thing');
      expect(item.updatedAt, DateTime.utc(2027, 1, 2));
      expect(item.auditablePassword, isNull);
      expect(item.toJson(), json);
      expect(jsonDecode(utf8.decode(item.encode())), json);
    });

    test('a newer schema version is not interpreted', () {
      final json = {...sampleItems().first.toJson(), 'v': 2};
      final item = VaultItem.fromJson(json);
      expect(item, isA<UnknownItem>());
      expect((item as UnknownItem).version, 2);
      expect(item.toJson(), json);
    });

    test('the pre-schema layout in the test vectors is an UnknownItem', () {
      const legacy =
          '{"type":"login","title":"Example","fields":{"username":"aziz",'
          '"password":"correct horse battery staple",'
          '"url":"https://example.com"}}';
      final item = VaultItem.decode(utf8.encode(legacy));
      expect(item, isA<UnknownItem>());
      expect(item.title, 'Example');
      expect((item as UnknownItem).version, isNull);
      expect(jsonEncode(item.toJson()), legacy);
    });
  });

  group('malformed plaintext', () {
    test('not JSON, not UTF-8, not an object', () {
      expect(() => VaultItem.decode(utf8.encode('not json')), throwsItemFormat);
      expect(() => VaultItem.decode(utf8.encode('[1,2]')), throwsItemFormat);
      expect(() => VaultItem.decode(utf8.encode('"x"')), throwsItemFormat);
      expect(() => VaultItem.decode(utf8.encode('')), throwsItemFormat);
      expect(
        () => VaultItem.decode(Uint8List.fromList([0xff, 0xfe, 0x7b])),
        throwsItemFormat,
      );
    });

    test('a missing or mistyped required field of every type', () {
      for (final item in sampleItems()) {
        final json = item.toJson();
        const optional = {'totp', 'secret', 'publicKey', 'passphrase'};
        for (final key in json.keys) {
          if (key == 'v' || key == 'type') continue;
          final without = {...json}..remove(key);
          if (optional.contains(key)) {
            expect(VaultItem.fromJson(without).toJson(), without);
          } else {
            expect(
              () => VaultItem.fromJson(without),
              throwsItemFormat,
              reason: '${item.type} without $key',
            );
          }
          expect(
            () => VaultItem.fromJson({...json, key: 42.5}),
            throwsItemFormat,
            reason: '${item.type} with numeric $key',
          );
        }
      }
    });

    test('urls must be a list of strings', () {
      final json = sampleItems().first.toJson();
      expect(
        () => VaultItem.fromJson({...json, 'urls': 'https://example.com'}),
        throwsItemFormat,
      );
      expect(
        () => VaultItem.fromJson({
          ...json,
          'urls': ['a', 1],
        }),
        throwsItemFormat,
      );
    });

    test('error messages name the field but not its value', () {
      final json = {...sampleItems().first.toJson(), 'password': 12345678};
      try {
        VaultItem.fromJson(json);
        fail('should have thrown');
      } on ItemFormatException catch (e) {
        expect(e.toString(), contains('password'));
        expect(e.toString(), isNot(contains('12345678')));
      }
    });
  });

  test('toString does not leak secrets', () {
    for (final item in sampleItems()) {
      final text = item.toString();
      expect(text, isNot(contains('correct horse')));
      expect(text, isNot(contains('hunter2')));
      expect(text, isNot(contains('4111')));
    }
  });
}
