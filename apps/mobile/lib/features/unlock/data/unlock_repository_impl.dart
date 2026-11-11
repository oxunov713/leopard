import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../../../core/network/remote_vault.dart';
import '../../../core/security/biometric_authenticator.dart';
import '../../../core/security/key_derivation.dart';
import '../../../core/session/vault_session.dart';
import '../../../core/storage/device_store.dart';
import '../domain/unlock_repository.dart';

final class UnlockRepositoryImpl implements UnlockRepository {
  UnlockRepositoryImpl({
    required DeviceStore store,
    required VaultSession session,
    required RemoteVault remote,
    required BiometricAuthenticator biometrics,
    required KeyDerivation keyDerivation,
    required LeopardCrypto crypto,
  }) : _store = store,
       _session = session,
       _remote = remote,
       _biometrics = biometrics,
       _keyDerivation = keyDerivation,
       _crypto = crypto;

  final DeviceStore _store;
  final VaultSession _session;
  final RemoteVault _remote;
  final BiometricAuthenticator _biometrics;
  final KeyDerivation _keyDerivation;
  final LeopardCrypto _crypto;

  @override
  Future<BiometricAvailability> biometricAvailability() =>
      _biometrics.availability();

  @override
  Future<BiometricOutcome> unlockWithBiometrics() async {
    final outcome = await _biometrics.authenticate(
      reason: 'Unlock your Leopard vault',
    );
    if (outcome != BiometricOutcome.success) {
      return outcome;
    }
    final secrets = await _store.readSecrets();
    try {
      await _open(vaultKey: secrets.vaultKey, deviceSeed: secrets.deviceSeed);
    } finally {
      secrets.destroy();
    }
    return outcome;
  }

  @override
  Future<bool> unlockWithMasterPassword(String masterPassword) async {
    final material = await _store.readMasterMaterial();
    final kek = await _keyDerivation.deriveKek(
      masterPassword: masterPassword,
      salt: material.salt,
      params: material.kdfParams,
    );
    Uint8List? vaultKey;
    DeviceSecrets? secrets;
    try {
      try {
        vaultKey = await _crypto.unwrapVaultKey(
          kek: kek,
          wrapped: material.wrappedVaultKey,
          label: WrapLabel.master,
        );
      } on DecryptException {
        return false;
      }
      secrets = await _store.readSecrets();
      await _open(vaultKey: vaultKey, deviceSeed: secrets.deviceSeed);
      return true;
    } finally {
      wipeAll([kek, vaultKey]);
      secrets?.destroy();
    }
  }

  /// Copies the keys into a new [UnlockedVault]; the caller wipes its own.
  Future<void> _open({
    required Uint8List vaultKey,
    required Uint8List deviceSeed,
  }) async {
    final registration = await _store.readRegistration();
    if (registration == null) {
      throw const StorageFailure('This phone is not set up.');
    }
    _remote.configure(registration.serverUrl);
    _session.open(
      UnlockedVault(
        deviceId: registration.deviceId,
        vaultKey: Uint8List.fromList(vaultKey),
        itemKey: await _crypto.deriveItemKey(vaultKey),
        deviceSeed: Uint8List.fromList(deviceSeed),
      ),
    );
  }
}
