import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:leopard_core/leopard_core.dart';

/// The expensive, password-based operations. Both run Argon2id (64 MiB,
/// three passes), which would freeze the UI for seconds on the main isolate.
abstract interface class KeyDerivation {
  /// Generates every secret of a new vault (crypto-spec §12, steps 1 to 4).
  Future<VaultSetupMaterial> createVaultSetup(String masterPassword);

  /// `KEK = Argon2id(NFC(password), salt, params)`.
  Future<Uint8List> deriveKek({
    required String masterPassword,
    required Uint8List salt,
    required KdfParams params,
  });
}

/// The crypto implementation used everywhere in the app: pure Dart, the one
/// the conformance vectors in `leopard_core` are tested against.
LeopardCrypto newLeopardCrypto() =>
    LeopardCrypto(cryptography: DartCryptography());

/// [KeyDerivation] that does the work in a short-lived background isolate.
final class IsolateKeyDerivation implements KeyDerivation {
  const IsolateKeyDerivation();

  @override
  Future<VaultSetupMaterial> createVaultSetup(String masterPassword) =>
      Isolate.run(() async {
        final password = LeopardCrypto.passwordBytes(masterPassword);
        try {
          return await newLeopardCrypto().createVaultSetup(password: password);
        } finally {
          wipe(password);
        }
      }, debugName: 'leopard-setup');

  @override
  Future<Uint8List> deriveKek({
    required String masterPassword,
    required Uint8List salt,
    required KdfParams params,
  }) => Isolate.run(() async {
    final password = LeopardCrypto.passwordBytes(masterPassword);
    try {
      return await newLeopardCrypto().deriveKek(
        password: password,
        salt: salt,
        params: params,
      );
    } finally {
      wipe(password);
    }
  }, debugName: 'leopard-kdf');
}
