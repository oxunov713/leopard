import 'dart:typed_data';

/// Moves an existing vault to this phone with the paper recovery key
/// (crypto-spec §8, `POST /v1/recovery/register-device`).
abstract interface class RestoreRepository {
  /// Registers this phone with the server at [serverUrl] and stores the
  /// vault key and a new device key on it, exactly where setup stores them.
  ///
  /// **The server signs out every other phone and every session** when it
  /// accepts the key. The vault is not opened yet: call [openRestoredVault].
  ///
  /// [masterPassword] is needed because the server does not return
  /// `wrapped_vk_master`: the phone wraps the recovered vault key under the
  /// password's KEK itself (salt and parameters come from the server) for the
  /// offline master-password unlock. Slow (Argon2id); runs off the UI
  /// isolate.
  ///
  /// Consumes (wipes) [recoveryKey], whatever the outcome.
  Future<void> restore({
    required Uri serverUrl,
    required String deviceLabel,
    required Uint8List recoveryKey,
    required String masterPassword,
  });

  /// Loads the keys [restore] stored into memory, as unlocking does. Only
  /// for the moment right after a successful [restore].
  Future<void> openRestoredVault();
}
