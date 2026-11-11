/// Base class of every error raised by the Leopard crypto layer.
///
/// Messages never contain key material, plaintext or passwords.
sealed class LeopardCryptoException implements Exception {
  const LeopardCryptoException(this.message);

  /// Human-readable description, safe to log.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Authenticated decryption failed: wrong key, wrong associated data (item
/// id, version, label or session id) or modified ciphertext. The cases are
/// deliberately indistinguishable.
final class DecryptException extends LeopardCryptoException {
  const DecryptException() : super('decryption failed');
}

/// An input has the wrong length.
final class InvalidSizeException extends LeopardCryptoException {
  const InvalidSizeException(super.message);
}

/// An input is not in the required text or wire format (base64url, Base32,
/// UUID, recovery key, QR URI).
final class InvalidFormatException extends LeopardCryptoException {
  const InvalidFormatException(super.message);
}

/// KDF parameters are malformed, weaker than the v1 minimum or absurdly
/// large (crypto-spec §5). A client MUST NOT run the KDF with them.
final class InvalidKdfParamsException extends LeopardCryptoException {
  const InvalidKdfParamsException(super.message);
}

/// A key is unusable, for example an X25519 public key of low order that
/// produces an all-zero shared secret.
final class InvalidKeyException extends LeopardCryptoException {
  const InvalidKeyException(super.message);
}
