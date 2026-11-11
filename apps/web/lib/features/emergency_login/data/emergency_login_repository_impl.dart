import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../../../core/network/leopard_api.dart';
import '../../../core/security/key_derivation.dart';
import '../../../core/session/vault_session.dart';
import '../domain/emergency_login_repository.dart';

/// [EmergencyLoginRepository] on the API and `leopard_core`'s crypto.
final class EmergencyLoginRepositoryImpl implements EmergencyLoginRepository {
  EmergencyLoginRepositoryImpl({
    required LeopardApi api,
    required VaultSession session,
    required LeopardCrypto crypto,
    required KeyDerivation keyDerivation,
    Map<String, Object?> Function()? clientInfo,
  }) : _api = api,
       _session = session,
       _crypto = crypto,
       _keyDerivation = keyDerivation,
       _clientInfo = clientInfo;

  final LeopardApi _api;
  final VaultSession _session;
  final LeopardCrypto _crypto;
  final KeyDerivation _keyDerivation;
  final Map<String, Object?> Function()? _clientInfo;

  /// The KDF parameters and salt, kept for the lifetime of the page.
  ///
  /// They are public (the server gives them to anyone) and fixed for a
  /// vault, and the endpoint allows only 5 requests per 5 minutes, so a
  /// mistyped code must not cost another request.
  MasterParams? _params;

  static final RegExp _sixDigits = RegExp(r'^\d{6}$');

  @override
  Future<void> login({
    required String masterPassword,
    required String totpCode,
    void Function(EmergencyLoginPhase phase)? onPhase,
  }) async {
    final code = totpCode.replaceAll(RegExp(r'\s'), '');
    if (masterPassword.isEmpty) {
      throw const ValidationFailure('Enter the master password.');
    }
    if (!_sixDigits.hasMatch(code)) {
      throw const ValidationFailure(
        'Enter the 6-digit code from your authenticator app.',
      );
    }

    onPhase?.call(EmergencyLoginPhase.fetchingParameters);
    // Already validated against the v1 minimum by the API client, so the
    // server cannot downgrade the KDF (crypto-spec §5).
    final params = _params ??= await _api.masterParams();

    Uint8List? kek;
    Uint8List? proof;
    Uint8List? vaultKey;
    try {
      onPhase?.call(EmergencyLoginPhase.derivingKey);
      kek = await _keyDerivation.deriveKek(
        masterPassword: masterPassword,
        salt: params.salt,
        params: params.kdfParams,
      );

      onPhase?.call(EmergencyLoginPhase.verifying);
      // The proof goes first; `wrapped_vk_master` comes back only if the
      // proof and the code are right (crypto-spec §6).
      proof = await _crypto.masterAuthKey(kek);
      final result = await _api.masterLogin(
        totpCode: code,
        proof: proof,
        clientInfo: _clientInfo?.call(),
      );
      try {
        vaultKey = await _crypto.unwrapVaultKey(
          kek: kek,
          wrapped: result.wrappedVkMaster,
          label: WrapLabel.master,
        );
      } on LeopardCryptoException {
        await _discardSession();
        throw const ServerMismatchFailure(
          'The server accepted the login but its copy of the vault key does '
          'not open with this password. Nothing was unlocked.',
        );
      }
      final itemKey = await _crypto.deriveItemKey(vaultKey);
      _session.open(
        UnlockedVault(
          vaultKey: vaultKey,
          itemKey: itemKey,
          sessionId: result.session.sessionId,
          method: LoginMethod.emergency,
          idleTimeout: Duration(seconds: result.session.idleTimeoutSeconds),
        ),
      );
      vaultKey = null; // now owned by the session
    } finally {
      wipeAll([kek, proof, vaultKey]);
    }
  }

  Future<void> _discardSession() async {
    try {
      await _api.logout();
    } on Object {
      _api.clearSession();
    }
  }
}
