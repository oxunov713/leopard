import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/core/error/failures.dart';
import 'package:leopard_mobile/core/storage/device_store.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

void main() {
  late MemoryKeyValueStore keyValues;
  late SecureDeviceStore store;

  final throwsStorage = throwsA(isA<StorageFailure>());

  DeviceSecrets secrets() => DeviceSecrets(
    vaultKey: bytesOf(keySize, 1),
    deviceSeed: bytesOf(ed25519SeedSize, 2),
  );
  MasterUnlockMaterial master() => MasterUnlockMaterial(
    wrappedVaultKey: bytesOf(wrappedVkSize, 3),
    salt: bytesOf(saltSize, 4),
    kdfParams: KdfParams.v1,
  );
  DeviceRegistration registration([Uri? url]) => DeviceRegistration(
    serverUrl: url ?? serverUrl,
    deviceId: deviceIdA,
    deviceLabel: 'Pixel 9',
  );

  setUp(() {
    keyValues = MemoryKeyValueStore();
    store = SecureDeviceStore(keyValues);
  });

  test('a fresh install has no registration', () async {
    expect(await store.readRegistration(), isNull);
    await expectLater(store.readSecrets(), throwsStorage);
    await expectLater(store.readMasterMaterial(), throwsStorage);
  });

  test('round trip', () async {
    await store.saveSecrets(secrets: secrets(), masterMaterial: master());
    await store.saveRegistration(registration());

    final r = (await store.readRegistration())!;
    expect(r.serverUrl, serverUrl);
    expect(r.deviceId, deviceIdA);
    expect(r.deviceLabel, 'Pixel 9');
    final s = await store.readSecrets();
    expect(s.vaultKey, bytesOf(keySize, 1));
    expect(s.deviceSeed, bytesOf(ed25519SeedSize, 2));
    final m = await store.readMasterMaterial();
    expect(m.wrappedVaultKey, bytesOf(wrappedVkSize, 3));
    expect(m.salt, bytesOf(saltSize, 4));
    expect(m.kdfParams, KdfParams.v1);
  });

  test('secrets alone do not make the phone "set up"', () async {
    // Setup stores the keys before calling the server; if the server call
    // fails the app must still offer setup.
    await store.saveSecrets(secrets: secrets(), masterMaterial: master());
    expect(await store.readRegistration(), isNull);
  });

  test('an http server address is never stored or accepted', () async {
    await expectLater(
      store.saveRegistration(
        registration(Uri.parse('http://vault.example.com')),
      ),
      throwsA(isA<ValidationFailure>()),
    );
    expect(keyValues.values, isEmpty);

    await store.saveRegistration(registration());
    keyValues.values['leopard.v1.server_url'] = 'http://vault.example.com';
    await expectLater(store.readRegistration(), throwsStorage);
  });

  test('damaged values are reported, not used', () async {
    await store.saveSecrets(secrets: secrets(), masterMaterial: master());
    await store.saveRegistration(registration());

    keyValues.values['leopard.v1.vault_key'] = 'AAAA'; // 3 bytes
    await expectLater(store.readSecrets(), throwsStorage);

    keyValues.values['leopard.v1.vault_key'] = 'not base64url!';
    await expectLater(store.readSecrets(), throwsStorage);

    keyValues.values['leopard.v1.kdf_params'] = '[]';
    await expectLater(store.readMasterMaterial(), throwsStorage);

    keyValues.values['leopard.v1.device_id'] = 'NOT-A-UUID';
    await expectLater(store.readRegistration(), throwsStorage);
  });

  test('erase removes everything', () async {
    await store.saveSecrets(secrets: secrets(), masterMaterial: master());
    await store.saveRegistration(registration());
    await store.erase();
    expect(keyValues.values, isEmpty);
    expect(await store.readRegistration(), isNull);
  });

  test('DeviceSecrets.destroy zeroes both keys', () {
    final s = secrets()..destroy();
    expect(s.vaultKey, everyElement(0));
    expect(s.deviceSeed, everyElement(0));
    expect(s.vaultKey, isA<Uint8List>());
  });
}
