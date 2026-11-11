import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/core/error/failures.dart';
import 'package:leopard_mobile/core/security/device_authenticator.dart';
import 'package:leopard_mobile/core/security/key_derivation.dart';
import 'package:leopard_mobile/core/session/vault_session.dart';
import 'package:leopard_mobile/core/storage/device_store.dart';
import 'package:leopard_mobile/features/unlock/data/unlock_repository_impl.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  final crypto = newLeopardCrypto();
  final vaultKey = bytesOf(keySize, 0x11);
  final deviceSeed = bytesOf(ed25519SeedSize, 0x51);
  final salt = bytesOf(saltSize, 0x21);
  // Stands in for Argon2id(password): the KDF itself is covered by the
  // vectors in leopard_core and by setup_repository_test.dart.
  final rightKek = bytesOf(keySize, 0x71);
  final wrongKek = bytesOf(keySize, 0x72);

  late MemoryKeyValueStore keyValues;
  late SecureDeviceStore store;
  late VaultSession session;
  late MockRemoteVault remote;
  late MockDeviceAuthenticator deviceAuth;
  late MockKeyDerivation kdf;
  late UnlockRepositoryImpl repository;

  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(KdfParams.v1);
    registerFallbackValue(Uri.parse('https://fallback.example'));
  });

  setUp(() async {
    keyValues = MemoryKeyValueStore();
    store = SecureDeviceStore(keyValues);
    await store.saveSecrets(
      secrets: DeviceSecrets(
        vaultKey: Uint8List.fromList(vaultKey),
        deviceSeed: Uint8List.fromList(deviceSeed),
      ),
      masterMaterial: MasterUnlockMaterial(
        wrappedVaultKey: await crypto.wrapVaultKey(
          kek: rightKek,
          vaultKey: vaultKey,
          label: WrapLabel.master,
        ),
        salt: salt,
        kdfParams: KdfParams.v1,
      ),
    );
    await store.saveRegistration(
      DeviceRegistration(
        serverUrl: serverUrl,
        deviceId: deviceIdA,
        deviceLabel: 'Pixel 9',
      ),
    );
    session = VaultSession();
    remote = MockRemoteVault();
    deviceAuth = MockDeviceAuthenticator();
    kdf = MockKeyDerivation();
    when(
      () => kdf.deriveKek(
        masterPassword: any(named: 'masterPassword'),
        salt: any(named: 'salt'),
        params: any(named: 'params'),
      ),
    ).thenAnswer(
      (invocation) async => Uint8List.fromList(
        invocation.namedArguments[#masterPassword] == 'right'
            ? rightKek
            : wrongKek,
      ),
    );
    repository = UnlockRepositoryImpl(
      store: store,
      session: session,
      remote: remote,
      deviceAuth: deviceAuth,
      keyDerivation: kdf,
      crypto: crypto,
    );
  });

  group('device credential unlock', () {
    test('success loads the keys into memory', () async {
      when(
        () => deviceAuth.authenticate(reason: any(named: 'reason')),
      ).thenAnswer((_) async => DeviceAuthOutcome.success);

      expect(
        await repository.unlockWithDeviceCredential(),
        DeviceAuthOutcome.success,
      );

      expect(session.isUnlocked, isTrue);
      final vault = session.require;
      expect(vault.vaultKey, vaultKey);
      expect(vault.deviceSeed, deviceSeed);
      expect(vault.deviceId, deviceIdA);
      expect(vault.itemKey, await crypto.deriveItemKey(vaultKey));
      verify(() => remote.configure(serverUrl)).called(1);
    });

    for (final outcome in [
      DeviceAuthOutcome.cancelled,
      DeviceAuthOutcome.lockedOut,
      DeviceAuthOutcome.noScreenLock,
      DeviceAuthOutcome.unavailable,
    ]) {
      test('$outcome: the keys are not even read', () async {
        final guarded = MockDeviceStore();
        final repository = UnlockRepositoryImpl(
          store: guarded,
          session: session,
          remote: remote,
          deviceAuth: deviceAuth,
          keyDerivation: kdf,
          crypto: crypto,
        );
        when(
          () => deviceAuth.authenticate(reason: any(named: 'reason')),
        ).thenAnswer((_) async => outcome);

        expect(await repository.unlockWithDeviceCredential(), outcome);

        expect(session.isUnlocked, isFalse);
        verifyNever(() => guarded.readSecrets());
        verifyNever(() => remote.configure(any()));
      });
    }
  });

  group('without a screen lock', () {
    test('the status is reported and nothing unlocks by itself', () async {
      when(
        deviceAuth.lockStatus,
      ).thenAnswer((_) async => DeviceLockStatus.none);
      expect(await repository.deviceLockStatus(), DeviceLockStatus.none);
      expect(session.isUnlocked, isFalse);
    });

    test('the master password still opens the vault', () async {
      when(
        deviceAuth.lockStatus,
      ).thenAnswer((_) async => DeviceLockStatus.none);
      expect(await repository.unlockWithMasterPassword('right'), isTrue);
      expect(session.isUnlocked, isTrue);
    });
  });

  group('master password fallback', () {
    test('the right password unwraps the vault key', () async {
      expect(await repository.unlockWithMasterPassword('right'), isTrue);

      expect(session.require.vaultKey, vaultKey);
      expect(session.require.deviceSeed, deviceSeed);
      verify(
        () => kdf.deriveKek(
          masterPassword: 'right',
          salt: salt,
          params: KdfParams.v1,
        ),
      ).called(1);
      verifyNever(() => deviceAuth.authenticate(reason: any(named: 'reason')));
    });

    test('a wrong password leaves the vault locked', () async {
      expect(await repository.unlockWithMasterPassword('wrong'), isFalse);
      expect(session.isUnlocked, isFalse);
      verifyNever(() => remote.configure(any()));
    });

    test('a weakened KDF configuration on disk is refused', () async {
      keyValues.values['leopard.v1.kdf_params'] =
          '{"alg":"argon2id","v":19,"m_kib":8,"t":1,"p":1,"dk_len":32,"salt_len":16}';
      await expectLater(
        repository.unlockWithMasterPassword('right'),
        throwsA(isA<StorageFailure>()),
      );
      verifyNever(
        () => kdf.deriveKek(
          masterPassword: any(named: 'masterPassword'),
          salt: any(named: 'salt'),
          params: any(named: 'params'),
        ),
      );
    });
  });
}
