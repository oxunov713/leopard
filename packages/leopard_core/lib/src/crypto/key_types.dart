import 'dart:typed_data';

import 'bytes.dart';
import 'kdf_params.dart';

/// Which key wraps the vault key; selects the AEAD associated data
/// (crypto-spec §5 and §8). A blob wrapped under one label cannot be
/// unwrapped under the other.
enum WrapLabel {
  /// `leopard/wrap/master/v1`: VK wrapped under the master-password KEK.
  master,

  /// `leopard/wrap/recovery/v1`: VK wrapped under the recovery KEK.
  recovery,
}

/// An X25519 key pair (RFC 7748). Used only for ephemeral QR-login keys.
final class X25519KeyPair {
  X25519KeyPair({required this.privateKey, required this.publicKey});

  /// 32-byte private key. Secret.
  final Uint8List privateKey;

  /// 32-byte public key.
  final Uint8List publicKey;

  /// Best-effort erasure of the private key (see [wipe]).
  void destroy() => wipe(privateKey);
}

/// An Ed25519 device key pair (RFC 8032).
final class Ed25519KeyPair {
  Ed25519KeyPair({required this.seed, required this.publicKey});

  /// 32-byte seed: the private key as stored in the platform keystore.
  /// Secret.
  final Uint8List seed;

  /// 32-byte public key, registered with the server.
  final Uint8List publicKey;

  /// Best-effort erasure of the seed (see [wipe]).
  void destroy() => wipe(seed);
}

/// The result of encrypting an item: the two fields stored by the server.
final class SealedItem {
  SealedItem({required this.nonce, required this.ciphertext});

  /// 12-byte AES-GCM nonce.
  final Uint8List nonce;

  /// `ciphertext || tag`.
  final Uint8List ciphertext;
}

/// Everything the phone sends to `POST /v1/qr/{sid}/approve`
/// (crypto-spec §10.1 step 6).
final class QrApproval {
  QrApproval({
    required this.phoneEphPub,
    required this.nonce,
    required this.ciphertext,
    required this.signature,
  });

  /// The phone's ephemeral X25519 public key, 32 bytes.
  final Uint8List phoneEphPub;

  /// 12-byte AES-GCM nonce.
  final Uint8List nonce;

  /// The vault key encrypted for the browser, 48 bytes.
  final Uint8List ciphertext;

  /// Ed25519 signature by the device key over the approval message, 64
  /// bytes.
  final Uint8List signature;
}

/// Everything generated on the phone at setup (crypto-spec §12).
///
/// The fields up to [totpSecret] go to `POST /v1/setup`. [vaultKey] and
/// [deviceKey] go to the platform keystore. [recoveryKey] is shown to the
/// user once and then destroyed. Call [destroy] when done.
final class VaultSetupMaterial {
  VaultSetupMaterial({
    required this.kdfParams,
    required this.salt,
    required this.wrappedVkMaster,
    required this.wrappedVkRecovery,
    required this.masterAuthVerifier,
    required this.recoveryAuthVerifier,
    required this.totpSecret,
    required this.deviceKey,
    required this.vaultKey,
    required this.recoveryKey,
  });

  /// Argon2id parameters used for the KEK.
  final KdfParams kdfParams;

  /// 16-byte Argon2id salt.
  final Uint8List salt;

  /// 60 bytes: VK wrapped under the master-password KEK.
  final Uint8List wrappedVkMaster;

  /// 60 bytes: VK wrapped under the recovery KEK.
  final Uint8List wrappedVkRecovery;

  /// SHA-256 of the master auth key.
  final Uint8List masterAuthVerifier;

  /// SHA-256 of the recovery auth key.
  final Uint8List recoveryAuthVerifier;

  /// 20 random bytes. Secret: sent to the server once and shown to the user
  /// as an `otpauth://` URI.
  final Uint8List totpSecret;

  /// The device key pair. Only the public half is sent to the server.
  final Ed25519KeyPair deviceKey;

  /// The vault key. Secret; never sent anywhere in the clear.
  final Uint8List vaultKey;

  /// The 16-byte recovery key. Secret; shown once, never stored or sent.
  final Uint8List recoveryKey;

  /// Best-effort erasure of every secret in this object (see [wipe]).
  void destroy() {
    wipeAll([vaultKey, recoveryKey, totpSecret]);
    deviceKey.destroy();
  }
}
