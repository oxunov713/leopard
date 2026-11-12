import 'dart:typed_data';

import '../../../core/error/failures.dart';

/// The server accepted the recovery key, so every other phone and session is
/// already signed out, but this phone could not finish. Nothing usable was
/// stored; restoring again with the same recovery key is safe.
final class RestoreIncompleteFailure extends AppFailure {
  const RestoreIncompleteFailure(this.cause)
    : super(
        'The server signed out every other phone and session, but this '
        'phone could not finish the restore. Your vault is unchanged. '
        'Restoring again with the same recovery key is safe.',
      );

  /// What went wrong after the server had accepted the key.
  final Object cause;
}

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
  /// password's KEK itself (salt and parameters from
  /// `GET /v1/auth/master/params`) for the offline master-password unlock.
  /// The KEK is derived (Argon2id, off the UI isolate) **before** the server
  /// is asked, so that only cheap steps remain once other devices are
  /// revoked. A failure after that point is a [RestoreIncompleteFailure].
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
