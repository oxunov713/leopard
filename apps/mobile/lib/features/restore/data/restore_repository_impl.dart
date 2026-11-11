import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../../../core/network/remote_vault.dart';
import '../../../core/security/key_derivation.dart';
import '../../../core/session/vault_session.dart';
import '../../../core/storage/device_store.dart';
import '../domain/restore_repository.dart';

final class RestoreRepositoryImpl implements RestoreRepository {
  RestoreRepositoryImpl({
    required DeviceStore store,
    required VaultSession session,
    required RemoteVault remote,
    required KeyDerivation keyDerivation,
    required LeopardCrypto crypto,
    ApiClientFactory clientFactory = defaultApiClientFactory,
  }) : _store = store,
       _session = session,
       _remote = remote,
       _keyDerivation = keyDerivation,
       _crypto = crypto,
       _clientFactory = clientFactory;

  final DeviceStore _store;
  final VaultSession _session;
  final RemoteVault _remote;
  final KeyDerivation _keyDerivation;
  final LeopardCrypto _crypto;
  final ApiClientFactory _clientFactory;

  @override
  Future<void> restore({
    required Uri serverUrl,
    required String deviceLabel,
    required Uint8List recoveryKey,
    required String masterPassword,
  }) async {
    final client = _clientFactory(serverUrl);
    Ed25519KeyPair? deviceKey;
    Uint8List? proof;
    Uint8List? recoveryKek;
    Uint8List? vaultKey;
    Uint8List? kek;
    try {
      // 1. A cheap check first, so that a wrong address does not spend one
      //    of the five recovery attempts an hour.
      try {
        if (!await client.health()) {
          throw const ValidationFailure(
            'The server answered, but reports that it is not ready.',
          );
        }
      } on ApiException {
        throw const ValidationFailure(
          'No Leopard server answered at this address.',
        );
      }

      // 2. Everything derived from the recovery key, then the key is gone.
      deviceKey = await _crypto.generateEd25519KeyPair();
      proof = await _crypto.recoveryAuthKey(recoveryKey);
      recoveryKek = await _crypto.recoveryKek(recoveryKey);
      wipe(recoveryKey);

      // 3. Register this phone. From here on every other device and session
      //    is revoked on the server.
      final result = await client.recoveryRegisterDevice(
        proof: proof,
        deviceLabel: deviceLabel,
        devicePublicKey: deviceKey.publicKey,
      );
      wipe(proof);

      // 4. VK from the recovery wrap.
      vaultKey = await _crypto.unwrapVaultKey(
        kek: recoveryKek,
        wrapped: result.wrappedVkRecovery,
        label: WrapLabel.recovery,
      );
      wipe(recoveryKek);

      // 5. The master-password fallback needs VK wrapped under the KEK. The
      //    server keeps its own copy and does not send it; this one has a
      //    fresh nonce but the same key, salt and parameters.
      kek = await _keyDerivation.deriveKek(
        masterPassword: masterPassword,
        salt: result.salt,
        params: result.kdfParams,
      );
      final wrappedVkMaster = await _crypto.wrapVaultKey(
        kek: kek,
        vaultKey: vaultKey,
        label: WrapLabel.master,
      );
      wipe(kek);

      // 6. Store as setup does: secrets first, the registration (which marks
      //    the phone as set up) last.
      final secrets = DeviceSecrets(
        vaultKey: Uint8List.fromList(vaultKey),
        deviceSeed: Uint8List.fromList(deviceKey.seed),
      );
      try {
        await _store.saveSecrets(
          secrets: secrets,
          masterMaterial: MasterUnlockMaterial(
            wrappedVaultKey: wrappedVkMaster,
            salt: result.salt,
            kdfParams: result.kdfParams,
          ),
        );
      } finally {
        secrets.destroy();
      }
      await _store.saveRegistration(
        DeviceRegistration(
          serverUrl: serverUrl,
          deviceId: result.deviceId,
          deviceLabel: deviceLabel,
        ),
      );
    } finally {
      wipeAll([recoveryKey, proof, recoveryKek, vaultKey, kek]);
      deviceKey?.destroy();
      client.close();
    }
  }

  @override
  Future<void> openRestoredVault() async {
    final registration = await _store.readRegistration();
    if (registration == null) {
      throw const StorageFailure('This phone is not set up.');
    }
    final secrets = await _store.readSecrets();
    try {
      _remote.configure(registration.serverUrl);
      _session.open(
        UnlockedVault(
          deviceId: registration.deviceId,
          vaultKey: Uint8List.fromList(secrets.vaultKey),
          itemKey: await _crypto.deriveItemKey(secrets.vaultKey),
          deviceSeed: Uint8List.fromList(secrets.deviceSeed),
        ),
      );
    } finally {
      secrets.destroy();
    }
  }
}
