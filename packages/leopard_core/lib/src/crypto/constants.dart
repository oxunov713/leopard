/// Sizes (in bytes) and domain-separation labels from `docs/crypto-spec.md`
/// §2.2 and §2.3. Changing any value here is a protocol change.
library;

/// VK, KEK, item key, auth keys and the QR transfer key.
const int keySize = 32;

/// AES-GCM nonce.
const int nonceSize = 12;

/// AES-GCM authentication tag.
const int tagSize = 16;

/// Argon2id salt.
const int saltSize = 16;

/// Recovery key (128 bits of entropy).
const int recoveryKeySize = 16;

/// QR session id (`sid`).
const int sidSize = 16;

/// X25519 private and public keys.
const int x25519KeySize = 32;

/// Ed25519 seed (the private key as stored by the device).
const int ed25519SeedSize = 32;

/// Ed25519 public key.
const int ed25519PublicKeySize = 32;

/// Ed25519 signature.
const int ed25519SignatureSize = 64;

/// Wrapped VK: `nonce || ciphertext || tag` for a 32-byte VK.
const int wrappedVkSize = nonceSize + keySize + tagSize;

/// QR transfer ciphertext: `ciphertext || tag` for a 32-byte VK.
const int qrCiphertextSize = keySize + tagSize;

/// Device-auth challenge nonce.
const int deviceChallengeSize = 32;

/// Session token and QR poll token.
const int tokenSize = 32;

/// Recommended TOTP secret size generated at setup (§7).
const int totpSecretSize = 20;

/// Length of a canonical UUID in text form.
const int uuidLength = 36;

/// HKDF info: item key.
const String infoItem = 'leopard/item/v1';

/// AEAD AAD: VK wrapped under the master KEK.
const String infoWrapMaster = 'leopard/wrap/master/v1';

/// HKDF info for the recovery KEK and AEAD AAD for the VK wrapped under it.
const String infoWrapRecovery = 'leopard/wrap/recovery/v1';

/// HKDF info: master auth key.
const String infoAuthMaster = 'leopard/auth/v1';

/// HKDF info: recovery auth key.
const String infoAuthRecovery = 'leopard/auth/recovery/v1';

/// HKDF info prefix: QR transfer key.
const String infoQr = 'leopard/qr/v1';

/// Signature prefix: QR approval.
const String labelQrApprove = 'leopard/qr-approve/v1';

/// Hash prefix: verification code.
const String labelVerify = 'leopard/verify/v1';

/// Signature prefix: device login.
const String labelDeviceAuth = 'leopard/device-auth/v1';

/// Largest item version this implementation accepts: 2^53 - 1, the largest
/// integer that is exact on every Dart platform (including JavaScript).
const int maxItemVersion = 9007199254740991;
