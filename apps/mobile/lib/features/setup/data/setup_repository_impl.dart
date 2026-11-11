import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../../../core/network/remote_vault.dart';
import '../../../core/security/key_derivation.dart';
import '../../../core/session/vault_session.dart';
import '../../../core/storage/device_store.dart';
import '../domain/setup_repository.dart';

final class SetupRepositoryImpl implements SetupRepository {
  SetupRepositoryImpl({
    required DeviceStore store,
    required VaultSession session,
    required RemoteVault remote,
    required KeyDerivation keyDerivation,
    required LeopardCrypto crypto,
    ApiClientFactory clientFactory = defaultApiClientFactory,
    DateTime Function() now = DateTime.now,
  }) : _store = store,
       _session = session,
       _remote = remote,
       _keyDerivation = keyDerivation,
       _crypto = crypto,
       _clientFactory = clientFactory,
       _now = now;

  final DeviceStore _store;
  final VaultSession _session;
  final RemoteVault _remote;
  final KeyDerivation _keyDerivation;
  final LeopardCrypto _crypto;
  final ApiClientFactory _clientFactory;
  final DateTime Function() _now;

  @override
  Future<void> checkServer(Uri serverUrl) async {
    final client = _clientFactory(serverUrl);
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
    } finally {
      client.close();
    }
  }

  @override
  Future<VaultSetupMaterial> prepare(String masterPassword) =>
      _keyDerivation.createVaultSetup(masterPassword);

  @override
  Future<bool> verifyTotpCode({
    required Uint8List secret,
    required String code,
  }) async {
    final digits = code.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^\d{6}$').hasMatch(digits)) {
      return false;
    }
    final seconds = _now().toUtc().millisecondsSinceEpoch ~/ 1000;
    var matched = false;
    for (final offset in const [-30, 0, 30]) {
      final at = seconds + offset;
      if (at < 0) {
        continue;
      }
      final expected = await _crypto.totpCode(secret: secret, unixSeconds: at);
      // No early exit: every window is always computed and compared.
      matched |= constantTimeEquals(expected.codeUnits, digits.codeUnits);
    }
    return matched;
  }

  @override
  Future<void> commit({
    required VaultSetupMaterial material,
    required Uri serverUrl,
    required String deviceLabel,
    String? setupToken,
  }) async {
    final secrets = DeviceSecrets(
      vaultKey: Uint8List.fromList(material.vaultKey),
      deviceSeed: Uint8List.fromList(material.deviceKey.seed),
    );
    final client = _clientFactory(serverUrl);
    try {
      // 1. Keys first: if this phone cannot store them, stop before the
      //    server has a vault that nothing could open.
      await _store.saveSecrets(
        secrets: secrets,
        masterMaterial: MasterUnlockMaterial(
          wrappedVaultKey: material.wrappedVkMaster,
          salt: material.salt,
          kdfParams: material.kdfParams,
        ),
      );
      // 2. Create the vault and register this phone.
      final token = setupToken?.trim();
      final result = await client.setup(
        material: material,
        deviceLabel: deviceLabel,
        setupToken: (token == null || token.isEmpty) ? null : token,
      );
      // 3. Remember where and who we are.
      await _store.saveRegistration(
        DeviceRegistration(
          serverUrl: serverUrl,
          deviceId: result.deviceId,
          deviceLabel: deviceLabel,
        ),
      );
      // 4. Unlock.
      _remote.configure(serverUrl);
      _session.open(
        UnlockedVault(
          deviceId: result.deviceId,
          vaultKey: Uint8List.fromList(secrets.vaultKey),
          itemKey: await _crypto.deriveItemKey(secrets.vaultKey),
          deviceSeed: Uint8List.fromList(secrets.deviceSeed),
        ),
      );
      material.destroy();
    } finally {
      secrets.destroy();
      client.close();
    }
  }
}
