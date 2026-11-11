import 'package:cryptography/dart.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:test/test.dart';

final now = DateTime.utc(2026, 11, 11, 12);

var _counter = 0;

String nextId() =>
    '00000000-0000-4000-8000-${(++_counter).toString().padLeft(12, '0')}';

AuditInput login(String title, String password, {DateTime? updatedAt}) =>
    AuditInput(
      id: nextId(),
      item: LoginItem(
        title: title,
        username: 'u',
        password: password,
        createdAt: DateTime.utc(2020),
        updatedAt: updatedAt ?? now,
      ),
    );

AuditInput wifi(String title, String password, {DateTime? updatedAt}) =>
    AuditInput(
      id: nextId(),
      item: WifiItem(
        title: title,
        ssid: title,
        password: password,
        createdAt: DateTime.utc(2020),
        updatedAt: updatedAt ?? now,
      ),
    );

AuditInput note(String title, String body) => AuditInput(
  id: nextId(),
  item: SecureNoteItem(
    title: title,
    body: body,
    createdAt: DateTime.utc(2020),
    updatedAt: DateTime.utc(2020),
  ),
);

void main() {
  final auditor = PasswordAuditor(cryptography: DartCryptography());
  const strong = r'vT9#qLx2!mRz8@Kp4$Wd';
  const strong2 = 'Hq7&nBv3*Zs5^Ty1(Uj9';

  group('weak', () {
    test('low entropy and common patterns are reported', () {
      final items = [
        login('strong', strong),
        login('short', 'k7M2z!'),
        login('common', 'Password123'),
        login('sequence', 'abcdefghijklmnop'),
        login('repeat', 'xyxyxyxyxyxyxyxyxyxy'),
        login('generated', generatePassword()),
        login('passphrase', generatePassphrase()),
      ];
      final weak = auditor.findWeak(items);
      expect(weak.map((f) => f.title), [
        'short',
        'common',
        'sequence',
        'repeat',
      ]);
      expect(weak[1].strength.patterns, contains(PasswordPattern.common));
      expect(weak[2].strength.patterns, contains(PasswordPattern.sequence));
      expect(weak[3].strength.patterns, contains(PasswordPattern.repeated));
      expect(weak.first.itemId, items[1].id);
    });

    test('the threshold is configurable', () {
      final lenient = PasswordAuditor(
        cryptography: DartCryptography(),
        weakThresholdBits: 30,
      );
      final strict = PasswordAuditor(
        cryptography: DartCryptography(),
        weakThresholdBits: 200,
      );
      final items = [login('short', 'k7M2z!'), login('strong', strong)];
      expect(lenient.findWeak(items), isEmpty);
      expect(strict.findWeak(items), hasLength(2));
    });

    test('a common password is weak whatever the threshold', () {
      final lenient = PasswordAuditor(
        cryptography: DartCryptography(),
        weakThresholdBits: 0,
      );
      expect(lenient.findWeak([login('c', 'qwerty')]), hasLength(1));
    });

    test('items without a password are skipped', () {
      final weak = auditor.findWeak([
        note('note', 'password'),
        wifi('open network', ''),
        AuditInput(
          id: nextId(),
          item: ApiKeyItem(
            title: 'api',
            service: 's',
            key: '1234',
            createdAt: now,
            updatedAt: now,
          ),
        ),
      ]);
      expect(weak, isEmpty);
    });
  });

  group('reused', () {
    test('groups items that share a password exactly', () async {
      final a = login('a', strong);
      final b = wifi('b', strong);
      final c = login('c', strong2);
      final d = login('d', strong);
      final e = login('e', strong2.toLowerCase());
      final f = login('f', '${strong2}x');
      final reused = await auditor.findReused([a, b, c, d, e, f]);
      expect(reused, hasLength(1));
      expect(reused.single.itemIds, [a.id, b.id, d.id]);
      expect(reused.single.titles, ['a', 'b', 'd']);
    });

    test('several groups, in first-seen order', () async {
      final items = [
        login('a1', strong),
        login('b1', strong2),
        login('b2', strong2),
        login('a2', strong),
        login('solo', 'unique-$strong'),
      ];
      final reused = await auditor.findReused(items);
      expect(reused.map((g) => g.titles), [
        ['a1', 'a2'],
        ['b1', 'b2'],
      ]);
    });

    test('empty passwords and non-password items are not "reused"', () async {
      final reused = await auditor.findReused([
        login('empty 1', ''),
        login('empty 2', ''),
        wifi('open 1', ''),
        note('n1', strong),
        note('n2', strong),
      ]);
      expect(reused, isEmpty);
    });

    test('findings never contain the password or a digest of it', () async {
      final reused = await auditor.findReused([
        login('a', strong),
        login('b', strong),
      ]);
      final finding = reused.single;
      final text = '${finding.itemIds} ${finding.titles}';
      expect(text, isNot(contains(strong)));
      expect(text, isNot(matches(RegExp('[0-9a-f]{64}'))));
    });
  });

  group('old', () {
    test('older than 365 days by the item updatedAt', () {
      final items = [
        login('fresh', strong, updatedAt: now),
        login(
          'just inside',
          strong,
          updatedAt: now.subtract(const Duration(days: 365)),
        ),
        login(
          'just outside',
          strong,
          updatedAt: now.subtract(const Duration(days: 365, seconds: 1)),
        ),
        wifi('ancient', strong, updatedAt: DateTime.utc(2021, 1, 1)),
        note('old note', 'x'),
      ];
      final old = auditor.findOld(items, now: now);
      expect(old.map((f) => f.title), ['just outside', 'ancient']);
      expect(old.first.age, const Duration(days: 365, seconds: 1));
      expect(old.last.updatedAt, DateTime.utc(2021, 1, 1));
    });

    test('the limit is configurable and local "now" is handled', () {
      final monthly = PasswordAuditor(
        cryptography: DartCryptography(),
        maxAge: const Duration(days: 30),
      );
      final item = login(
        'x',
        strong,
        updatedAt: now.subtract(const Duration(days: 31)),
      );
      expect(monthly.findOld([item], now: now.toLocal()), hasLength(1));
      expect(auditor.findOld([item], now: now.toLocal()), isEmpty);
    });

    test('an item dated in the future is not old', () {
      final item = login(
        'x',
        strong,
        updatedAt: now.add(const Duration(days: 900)),
      );
      expect(auditor.findOld([item], now: now), isEmpty);
    });
  });

  test('audit runs all three checks', () async {
    final report = await auditor.audit([
      login('weak+old', 'letmein', updatedAt: DateTime.utc(2022)),
      login('reused 1', strong),
      login('reused 2', strong),
      note('ignored', 'letmein'),
    ], now: now);
    expect(report.checked, 3);
    expect(report.weak.single.title, 'weak+old');
    expect(report.old.single.title, 'weak+old');
    expect(report.reused.single.titles, ['reused 1', 'reused 2']);
    expect(report.isClean, isFalse);

    final clean = await auditor.audit([
      login('a', strong),
      login('b', strong2),
    ], now: now);
    expect(clean.isClean, isTrue);
    expect(clean.checked, 2);
  });
}
