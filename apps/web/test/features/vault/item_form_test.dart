import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/core/error/failures.dart';
import 'package:leopard_web/features/vault/domain/item_form.dart';
import 'package:leopard_web/features/vault/domain/vault_entry.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  final now = DateTime.utc(2026, 12, 1, 8, 30);
  final throwsValidation = throwsA(isA<ValidationFailure>());

  test('every item type of the schema has a form', () {
    expect(itemFieldSpecs.keys, itemTypeLabels.keys);
    for (final specs in itemFieldSpecs.values) {
      expect(specs.first.key, 'title');
    }
  });

  test('a card has no field for the verification code', () {
    final keys = itemFieldSpecs[CardItem.typeName]!.map((s) => s.key).toSet();
    expect(keys.intersection(CardItem.forbiddenKeys), isEmpty);
    for (final spec in itemFieldSpecs[CardItem.typeName]!) {
      expect(spec.label.toLowerCase(), isNot(contains('cvv')));
      expect(spec.label.toLowerCase(), isNot(contains('cvc')));
      expect(spec.label.toLowerCase(), isNot(contains('security code')));
    }
  });

  test('passwords, keys and note bodies are marked secret', () {
    bool secret(String type, String key) =>
        itemFieldSpecs[type]!.firstWhere((s) => s.key == key).secret;
    expect(secret(LoginItem.typeName, 'password'), isTrue);
    expect(secret(LoginItem.typeName, 'totp'), isTrue);
    expect(secret(CardItem.typeName, 'number'), isTrue);
    expect(secret(WifiItem.typeName, 'password'), isTrue);
    expect(secret(ApiKeyItem.typeName, 'key'), isTrue);
    expect(secret(ApiKeyItem.typeName, 'secret'), isTrue);
    expect(secret(SshKeyItem.typeName, 'privateKey'), isTrue);
    expect(secret(SshKeyItem.typeName, 'passphrase'), isTrue);
    expect(secret(SecureNoteItem.typeName, 'body'), isTrue);
    expect(secret(LoginItem.typeName, 'username'), isFalse);
  });

  group('buildItem', () {
    test('login: secrets as typed, labels trimmed, URLs split', () {
      final item =
          buildItem(
                type: LoginItem.typeName,
                now: now,
                values: {
                  'title': '  Example  ',
                  'username': ' aziz ',
                  'password': '  spaces matter  ',
                  'urls': 'https://a.example\n\n  https://b.example  \n',
                  'totp': '',
                  'notes': 'n',
                },
              )
              as LoginItem;
      expect(item.title, 'Example');
      expect(item.username, 'aziz');
      expect(item.password, '  spaces matter  ');
      expect(item.urls, ['https://a.example', 'https://b.example']);
      expect(item.totp, isNull);
      expect(item.createdAt, now);
      expect(item.updatedAt, now);
      // Optional members are omitted, not written as null (§14.1).
      expect(item.toJson().containsKey('totp'), isFalse);
    });

    test('every type round-trips through its form values', () {
      final items = <VaultItem>[
        login('L'),
        CardItem(
          title: 'C',
          holder: 'A. Example',
          number: '4111 1111 1111 1111',
          expMonth: 9,
          expYear: 2031,
          createdAt: t0,
          updatedAt: t0,
        ),
        WifiItem(
          title: 'W',
          ssid: 'home',
          password: 'pw',
          security: WifiItem.securityWpa3,
          createdAt: t0,
          updatedAt: t0,
        ),
        ApiKeyItem(
          title: 'K',
          service: 'S3',
          key: 'AKIA',
          secret: 's',
          createdAt: t0,
          updatedAt: t0,
        ),
        SshKeyItem(
          title: 'S',
          privateKey: '-----BEGIN-----\nabc\n',
          publicKey: 'ssh-ed25519 AAAA a@b',
          createdAt: t0,
          updatedAt: t0,
        ),
        SecureNoteItem(
          title: 'N',
          body: 'line 1\nline 2',
          createdAt: t0,
          updatedAt: t0,
        ),
      ];
      for (final original in items) {
        final rebuilt = buildItem(
          type: original.type,
          values: itemFormValues(original),
          now: now,
          original: original,
        );
        final a = original.toJson()..remove('updatedAt');
        final b = rebuilt.toJson()..remove('updatedAt');
        expect(b, a, reason: original.type);
        expect(rebuilt.createdAt, t0, reason: 'createdAt never changes');
        expect(rebuilt.updatedAt, now, reason: 'updatedAt is set on edit');
      }
    });

    test('unknown members written by another client are preserved', () {
      final original = LoginItem(
        title: 'L',
        username: 'u',
        password: 'p',
        createdAt: t0,
        updatedAt: t0,
        extra: const {
          'passkey': {'id': 'abc'},
          'favourite': true,
        },
      );
      final rebuilt = buildItem(
        type: LoginItem.typeName,
        values: {...itemFormValues(original), 'password': 'p2'},
        now: now,
        original: original,
      );
      expect(rebuilt.toJson()['passkey'], {'id': 'abc'});
      expect(rebuilt.toJson()['favourite'], true);
      expect((rebuilt as LoginItem).password, 'p2');
    });

    test('validation', () {
      VaultItem card(Map<String, String> v) => buildItem(
        type: CardItem.typeName,
        now: now,
        values: {
          'title': 'C',
          'number': '4111',
          'expMonth': '9',
          'expYear': '2031',
          ...v,
        },
      );
      expect(card({}), isA<CardItem>());
      expect(() => card({'title': '  '}), throwsValidation);
      expect(() => card({'expMonth': '13'}), throwsValidation);
      expect(() => card({'expMonth': 'x'}), throwsValidation);
      expect(() => card({'expYear': '31'}), throwsValidation);
      expect(() => card({'number': ''}), throwsValidation);
      expect(
        () => buildItem(type: 'passkey', values: {'title': 'x'}, now: now),
        throwsValidation,
      );
      expect(
        () => buildItem(
          type: WifiItem.typeName,
          values: {'title': 'x', 'ssid': 'y'},
          now: now,
          original: login('L'),
        ),
        throwsValidation,
        reason: 'the type of an existing item cannot change',
      );
    });

    test('an unknown Wi-Fi security value is kept unchanged', () {
      final item =
          buildItem(
                type: WifiItem.typeName,
                now: now,
                values: {'title': 'W', 'ssid': 's', 'security': 'wpa4-future'},
              )
              as WifiItem;
      expect(item.security, 'wpa4-future');
    });
  });

  test('list subtitles never show a secret', () {
    expect(entrySubtitle(login('L', username: 'aziz')), 'aziz');
    expect(
      entrySubtitle(
        CardItem(
          title: 'C',
          holder: 'H',
          number: '4111 1111 1111 1234',
          expMonth: 1,
          expYear: 2030,
          createdAt: t0,
          updatedAt: t0,
        ),
      ),
      '•••• 1234',
    );
    expect(
      entrySubtitle(
        SecureNoteItem(
          title: 'N',
          body: 'secret',
          createdAt: t0,
          updatedAt: t0,
        ),
      ),
      '',
    );
    expect(
      entrySubtitle(
        SshKeyItem(
          title: 'S',
          privateKey: 'PRIVATE',
          publicKey: 'ssh-ed25519 AAAA me',
          createdAt: t0,
          updatedAt: t0,
        ),
      ),
      'ssh-ed25519',
    );
  });
}
