import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

/// The expensive, password-based step of the emergency login.
abstract interface class KeyDerivation {
  /// `KEK = Argon2id(NFC(password), salt, params)` (crypto-spec §5).
  ///
  /// The caller owns the returned key and must wipe it.
  Future<Uint8List> deriveKek({
    required String masterPassword,
    required Uint8List salt,
    required KdfParams params,
  });
}

/// [KeyDerivation] on the page's own thread, through `leopard_core`.
///
/// Web Crypto has no Argon2, so in a browser this is `package:cryptography`'s
/// Dart implementation compiled to JavaScript: 64 MiB and three passes take
/// several seconds, sometimes tens of seconds on a slow machine. The
/// implementation hands control back to the event loop every 500 memory
/// blocks (a few hundred times per derivation), so the page keeps painting
/// and the "deriving key" screen stays alive, though animations stutter.
///
/// A dedicated web worker would remove the stutter. It needs a second
/// compiled entry point, a `worker-src` rule in the site's CSP and a message
/// protocol that carries the master password to another thread, and it is
/// not used here; the trade-off is described in the README. Everything that
/// would change is behind this interface.
final class InlineKeyDerivation implements KeyDerivation {
  const InlineKeyDerivation(this._crypto);

  final LeopardCrypto _crypto;

  @override
  Future<Uint8List> deriveKek({
    required String masterPassword,
    required Uint8List salt,
    required KdfParams params,
  }) async {
    final password = LeopardCrypto.passwordBytes(masterPassword);
    try {
      return await _crypto.deriveKek(
        password: password,
        salt: salt,
        params: params,
      );
    } finally {
      wipe(password);
    }
  }
}
