import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/features/vault/domain/item_copy.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  test('a login copies its password with Ctrl+C and its username with '
      'Ctrl+B', () {
    final item = login('GitHub', username: 'octo', password: 's3cret');
    expect(primarySecretField(item)?.value, 's3cret');
    expect(primarySecretField(item)?.key, 'password');
    expect(primaryPlainField(item)?.value, 'octo');
    expect(primaryPlainField(item)?.label, 'Username');
  });

  test('empty fields are skipped, and nothing is invented', () {
    final item = login('No secrets', username: '', password: '');
    expect(primarySecretField(item), isNull);
    expect(primaryPlainField(item), isNull);
  });

  test('other types pick their own secret and plain field', () {
    final wifi = WifiItem(
      title: 'Home',
      ssid: 'TP-Link_5G',
      password: 'hunter2',
      security: WifiItem.securityWpa2,
      notes: '',
      createdAt: t0,
      updatedAt: t0,
    );
    expect(primarySecretField(wifi)?.value, 'hunter2');
    expect(primaryPlainField(wifi)?.value, 'TP-Link_5G');

    final key = ApiKeyItem(
      title: 'Render',
      service: 'render.com',
      key: 'rnd_abc',
      notes: '',
      createdAt: t0,
      updatedAt: t0,
    );
    expect(primarySecretField(key)?.value, 'rnd_abc');
    expect(primaryPlainField(key)?.value, 'render.com');
  });
}
