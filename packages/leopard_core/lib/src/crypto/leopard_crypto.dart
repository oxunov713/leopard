import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'bytes.dart';
import 'constants.dart';
import 'encoding.dart';
import 'errors.dart';
import 'kdf_params.dart';
import 'key_types.dart';
import 'secure_random.dart';

/// The client side of the Leopard cryptographic protocol, as specified in
/// `docs/crypto-spec.md`. The Go reference implementation is
/// `backend/internal/crypto/crypto.go`; both must reproduce
/// `docs/test-vectors.json` byte for byte.
///
/// Two layers:
///
/// * **Deterministic primitives** take every nonce, salt and key as an
///   explicit argument, mirror the Go functions one to one and are what the
///   test vectors exercise.
/// * **Random-nonce helpers** ([generateVaultKey], [encryptItem],
///   [wrapVaultKey], [approveQrLogin], [createVaultSetup], …) draw fresh
///   values from `Random.secure()`. Application code should use these.
///
/// Sizes are validated before any cryptographic work and reported as
/// [InvalidSizeException]. Every authenticated-decryption failure is a
/// [DecryptException].
///
/// **Memory hygiene.** Functions that derive intermediate secrets overwrite
/// them before returning, and callers should [wipe] returned keys when done.
/// This is best effort: see [wipe] for what Dart cannot guarantee.
final class LeopardCrypto {
  /// Creates the crypto layer on top of [cryptography].
  ///
  /// The default is `Cryptography.instance` (pure Dart on the VM, Web Crypto
  /// in browsers). Flutter apps should pass `FlutterCryptography` from
  /// `package:cryptography_flutter` for hardware-accelerated AES-GCM and a
  /// native Argon2id.
  LeopardCrypto({Cryptography? cryptography})
    : _cryptography = cryptography ?? Cryptography.instance;

  final Cryptography _cryptography;

  late final AesGcm _aesGcm = _cryptography.aesGcm(
    secretKeyLength: keySize,
    nonceLength: nonceSize,
  );
  late final Hkdf _hkdf = _cryptography.hkdf(
    hmac: _cryptography.hmac(_cryptography.sha256()),
    outputLength: keySize,
  );
  late final Sha256 _sha256 = _cryptography.sha256();
  late final Hmac _hmacSha1 = _cryptography.hmac(_cryptography.sha1());
  late final X25519 _x25519 = _cryptography.x25519();
  late final Ed25519 _ed25519 = _cryptography.ed25519();

  // ---- Primitives (crypto-spec §2.1) ----

  /// SHA-256.
  Future<Uint8List> sha256(List<int> data) async {
    final hash = await _sha256.hash(data);
    return Uint8List.fromList(hash.bytes);
  }

  /// HKDF-SHA256 (RFC 5869, extract-then-expand) with a 32-byte output.
  /// An empty [salt] is the "salt = empty" of the spec.
  Future<Uint8List> hkdf32({
    required Uint8List ikm,
    required List<int> salt,
    required List<int> info,
  }) async {
    final derived = await _hkdf.deriveKey(
      secretKey: SecretKeyData(ikm),
      nonce: salt,
      info: info,
    );
    return Uint8List.fromList(derived.bytes);
  }

  /// AES-256-GCM. Returns `ciphertext || tag`; the nonce is not included.
  ///
  /// [nonce] MUST be fresh for every encryption under the same [key].
  Future<Uint8List> seal({
    required Uint8List key,
    required Uint8List nonce,
    required List<int> plaintext,
    required List<int> aad,
  }) async {
    checkSize(key, keySize, 'key');
    checkSize(nonce, nonceSize, 'nonce');
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKeyData(key),
      nonce: nonce,
      aad: aad,
    );
    return box.concatenation(nonce: false);
  }

  /// Reverses [seal]. Throws [DecryptException] if the tag does not verify.
  Future<Uint8List> open({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required List<int> aad,
  }) async {
    checkSize(key, keySize, 'key');
    checkSize(nonce, nonceSize, 'nonce');
    if (ciphertext.length < tagSize) {
      throw const InvalidSizeException('ciphertext is shorter than the tag');
    }
    final split = ciphertext.length - tagSize;
    final box = SecretBox(
      Uint8List.sublistView(ciphertext, 0, split),
      nonce: nonce,
      mac: Mac(Uint8List.sublistView(ciphertext, split)),
    );
    final List<int> clear;
    try {
      clear = await _aesGcm.decrypt(
        box,
        secretKey: SecretKeyData(key),
        aad: aad,
      );
    } on Exception {
      // SecretBoxAuthenticationError, or whatever a platform implementation
      // reports for a tag mismatch. Never reveal which.
      throw const DecryptException();
    }
    return Uint8List.fromList(clear);
  }

  // ---- Vault key and items (§3, §4) ----

  /// `VK = random(32)`. Generated once, on the phone, at setup.
  Uint8List generateVaultKey() => randomBytes(keySize);

  /// `item_key = HKDF(ikm = VK, salt = empty, info = "leopard/item/v1")`.
  Future<Uint8List> deriveItemKey(Uint8List vaultKey) async {
    checkSize(vaultKey, keySize, 'vault key');
    return hkdf32(ikm: vaultKey, salt: const [], info: asciiBytes(infoItem));
  }

  /// The item AAD: `item_id` (36 ASCII bytes of the canonical lower-case
  /// UUID) followed by `version` as a big-endian uint64; 44 bytes.
  ///
  /// [version] must be in `[0, 2^53 - 1]` so that it is exact on JavaScript.
  static Uint8List itemAad(String itemId, int version) {
    final id = uuidAsciiBytes(itemId, 'item id');
    if (version < 0 || version > maxItemVersion) {
      throw const InvalidSizeException('item version out of range');
    }
    final aad = Uint8List(uuidLength + 8)..setRange(0, uuidLength, id);
    // Written as two 32-bit halves: 64-bit integer accessors are not
    // available when compiled to JavaScript.
    ByteData.sublistView(aad)
      ..setUint32(uuidLength, version ~/ 0x100000000)
      ..setUint32(uuidLength + 4, version % 0x100000000);
    return aad;
  }

  /// Encrypts an item's plaintext with an explicit [nonce]. Returns
  /// `ciphertext || tag`.
  ///
  /// [version] is the version the item will have *after* the write: `1` for
  /// a new item, `expected_version + 1` for an update. Prefer [encryptItem],
  /// which picks the nonce.
  Future<Uint8List> sealItem({
    required Uint8List itemKey,
    required Uint8List nonce,
    required String itemId,
    required int version,
    required List<int> plaintext,
  }) async {
    final aad = itemAad(itemId, version);
    return seal(key: itemKey, nonce: nonce, plaintext: plaintext, aad: aad);
  }

  /// Encrypts an item's plaintext under a fresh random nonce.
  Future<SealedItem> encryptItem({
    required Uint8List itemKey,
    required String itemId,
    required int version,
    required List<int> plaintext,
  }) async {
    final nonce = randomBytes(nonceSize);
    final ciphertext = await sealItem(
      itemKey: itemKey,
      nonce: nonce,
      itemId: itemId,
      version: version,
      plaintext: plaintext,
    );
    return SealedItem(nonce: nonce, ciphertext: ciphertext);
  }

  /// Decrypts an item using the `id` and `version` returned by the server.
  /// Throws [DecryptException] if the ciphertext was produced for a
  /// different item id or version, or was modified.
  Future<Uint8List> openItem({
    required Uint8List itemKey,
    required Uint8List nonce,
    required String itemId,
    required int version,
    required Uint8List ciphertext,
  }) async {
    final aad = itemAad(itemId, version);
    return open(key: itemKey, nonce: nonce, ciphertext: ciphertext, aad: aad);
  }

  // ---- Master password (§5, §6) ----

  /// A master password in Unicode Normalization Form C (crypto-spec §5).
  ///
  /// The same password can reach the app as different code point sequences
  /// depending on the keyboard: "é" is U+00E9 from one and U+0065 U+0301 from
  /// another. NFC maps both to one sequence, so the password unlocks the vault
  /// whichever device it is typed on. Nothing else is changed: no trimming,
  /// no case folding and no compatibility (NFKC) mapping.
  static String normalizePassword(String password) => unorm.nfc(password);

  /// The bytes of a master password that go into the KDF: UTF-8 of the NFC
  /// form of [password] (see [normalizePassword]).
  ///
  /// Every client MUST derive the password bytes through this function.
  static Uint8List passwordBytes(String password) =>
      utf8.encode(normalizePassword(password));

  /// `KEK = Argon2id(password, salt, params)`.
  ///
  /// [params] are validated first ([KdfParams.validate]); parameters
  /// received from a server MUST go through this check, which stops a
  /// downgrade. This call needs [KdfParams.memoryKib] KiB of memory and can
  /// take seconds; with the pure-Dart implementation it blocks the calling
  /// isolate, so UI code should run it in a background isolate or inject a
  /// native implementation.
  Future<Uint8List> deriveKek({
    required Uint8List password,
    required Uint8List salt,
    KdfParams params = KdfParams.v1,
  }) async {
    params.validate();
    checkSize(salt, params.saltLength, 'salt');
    final argon2id = _cryptography.argon2id(
      memory: params.memoryKib,
      parallelism: params.parallelism,
      iterations: params.iterations,
      hashLength: params.keyLength,
    );
    final derived = await argon2id.deriveKey(
      secretKey: SecretKeyData(password),
      nonce: salt,
    );
    final kek = Uint8List.fromList(await derived.extractBytes());
    checkSize(kek, keySize, 'derived key');
    return kek;
  }

  /// `nonce || AEAD.Seal(kek, nonce, vk, aad = label)`; 60 bytes. Prefer
  /// [wrapVaultKey], which picks the nonce.
  Future<Uint8List> wrapVaultKeyWithNonce({
    required Uint8List kek,
    required Uint8List nonce,
    required Uint8List vaultKey,
    required WrapLabel label,
  }) async {
    checkSize(vaultKey, keySize, 'vault key');
    final sealed = await seal(
      key: kek,
      nonce: nonce,
      plaintext: vaultKey,
      aad: _wrapAad(label),
    );
    return concatBytes([nonce, sealed]);
  }

  /// Wraps the vault key under [kek] with a fresh random nonce.
  Future<Uint8List> wrapVaultKey({
    required Uint8List kek,
    required Uint8List vaultKey,
    required WrapLabel label,
  }) async => wrapVaultKeyWithNonce(
    kek: kek,
    nonce: randomBytes(nonceSize),
    vaultKey: vaultKey,
    label: label,
  );

  /// Reverses [wrapVaultKey]. Throws [DecryptException] for a wrong KEK, a
  /// wrong [label] or a modified blob.
  Future<Uint8List> unwrapVaultKey({
    required Uint8List kek,
    required Uint8List wrapped,
    required WrapLabel label,
  }) async {
    checkSize(wrapped, wrappedVkSize, 'wrapped vault key');
    return open(
      key: kek,
      nonce: Uint8List.sublistView(wrapped, 0, nonceSize),
      ciphertext: Uint8List.sublistView(wrapped, nonceSize),
      aad: _wrapAad(label),
    );
  }

  /// `master_auth_key = HKDF(KEK, salt = empty, info = "leopard/auth/v1")`.
  /// Sent as the login `proof`; the server stores only [authVerifier] of it.
  Future<Uint8List> masterAuthKey(Uint8List kek) async {
    checkSize(kek, keySize, 'KEK');
    return hkdf32(ikm: kek, salt: const [], info: asciiBytes(infoAuthMaster));
  }

  /// `SHA256(auth_key)`: the value the server stores.
  Future<Uint8List> authVerifier(Uint8List authKey) async {
    checkSize(authKey, keySize, 'auth key');
    return sha256(authKey);
  }

  // ---- Recovery key (§6, §8) ----

  /// `recovery_key = random(16)`.
  Uint8List generateRecoveryKey() => randomBytes(recoveryKeySize);

  /// `RK_KEK = HKDF(recovery_key, salt = empty,
  /// info = "leopard/wrap/recovery/v1")`.
  Future<Uint8List> recoveryKek(Uint8List recoveryKey) async {
    checkSize(recoveryKey, recoveryKeySize, 'recovery key');
    return hkdf32(
      ikm: recoveryKey,
      salt: const [],
      info: asciiBytes(infoWrapRecovery),
    );
  }

  /// `recovery_auth_key = HKDF(recovery_key, salt = empty,
  /// info = "leopard/auth/recovery/v1")`.
  Future<Uint8List> recoveryAuthKey(Uint8List recoveryKey) async {
    checkSize(recoveryKey, recoveryKeySize, 'recovery key');
    return hkdf32(
      ikm: recoveryKey,
      salt: const [],
      info: asciiBytes(infoAuthRecovery),
    );
  }

  // ---- X25519 and the QR transfer (§10) ----

  /// A fresh ephemeral X25519 key pair.
  Future<X25519KeyPair> generateX25519KeyPair() async {
    final privateKey = randomBytes(x25519KeySize);
    return X25519KeyPair(
      privateKey: privateKey,
      publicKey: await x25519PublicKey(privateKey),
    );
  }

  /// The public key for a 32-byte X25519 private key.
  Future<Uint8List> x25519PublicKey(Uint8List privateKey) async {
    checkSize(privateKey, x25519KeySize, 'X25519 private key');
    final keyPair = await _x25519.newKeyPairFromSeed(privateKey);
    final publicKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  /// The raw X25519 shared secret (RFC 7748).
  ///
  /// Throws [InvalidKeyException] if the result is all zero (the peer sent a
  /// low-order point), as the spec requires.
  Future<Uint8List> x25519SharedSecret({
    required Uint8List privateKey,
    required Uint8List peerPublicKey,
  }) async {
    checkSize(privateKey, x25519KeySize, 'X25519 private key');
    checkSize(peerPublicKey, x25519KeySize, 'X25519 public key');
    final Uint8List shared;
    try {
      final keyPair = await _x25519.newKeyPairFromSeed(privateKey);
      final secret = await _x25519.sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: SimplePublicKey(
          peerPublicKey,
          type: KeyPairType.x25519,
        ),
      );
      shared = Uint8List.fromList(await secret.extractBytes());
    } on Object {
      // Some platform implementations (Web Crypto) refuse low-order points
      // themselves, with implementation-specific errors.
      throw const InvalidKeyException('X25519 key agreement failed');
    }
    if (shared.length != x25519KeySize || isAllZero(shared)) {
      throw const InvalidKeyException('X25519 shared secret is all zero');
    }
    return shared;
  }

  /// `HKDF(ikm = shared, salt = sid,
  /// info = "leopard/qr/v1" || browser_pub || phone_eph_pub)`.
  Future<Uint8List> qrTransferKey({
    required Uint8List sharedSecret,
    required Uint8List sid,
    required Uint8List browserPub,
    required Uint8List phoneEphPub,
  }) async {
    checkSize(sharedSecret, x25519KeySize, 'shared secret');
    checkSize(sid, sidSize, 'sid');
    checkSize(browserPub, x25519KeySize, 'browser_pub');
    checkSize(phoneEphPub, x25519KeySize, 'phone_eph_pub');
    return hkdf32(
      ikm: sharedSecret,
      salt: sid,
      info: concatBytes([asciiBytes(infoQr), browserPub, phoneEphPub]),
    );
  }

  /// Phone side: encrypts VK for the browser with explicit ephemeral key
  /// and nonce. Returns `ciphertext || tag` (48 bytes); the AAD is `sid`.
  /// Prefer [approveQrLogin].
  Future<Uint8List> qrSealVaultKey({
    required Uint8List phoneEphPrivateKey,
    required Uint8List browserPub,
    required Uint8List sid,
    required Uint8List nonce,
    required Uint8List vaultKey,
  }) async {
    checkSize(vaultKey, keySize, 'vault key');
    checkSize(sid, sidSize, 'sid');
    checkSize(nonce, nonceSize, 'nonce');
    final phoneEphPub = await x25519PublicKey(phoneEphPrivateKey);
    final shared = await x25519SharedSecret(
      privateKey: phoneEphPrivateKey,
      peerPublicKey: browserPub,
    );
    Uint8List? key;
    try {
      key = await qrTransferKey(
        sharedSecret: shared,
        sid: sid,
        browserPub: browserPub,
        phoneEphPub: phoneEphPub,
      );
      return await seal(key: key, nonce: nonce, plaintext: vaultKey, aad: sid);
    } finally {
      wipeAll([shared, key]);
    }
  }

  /// Browser side: recovers VK from the approval payload. Throws
  /// [DecryptException] if the payload was not made for this browser key
  /// and this `sid`.
  Future<Uint8List> qrOpenVaultKey({
    required Uint8List browserPrivateKey,
    required Uint8List phoneEphPub,
    required Uint8List sid,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) async {
    checkSize(ciphertext, qrCiphertextSize, 'QR ciphertext');
    checkSize(sid, sidSize, 'sid');
    checkSize(nonce, nonceSize, 'nonce');
    final browserPub = await x25519PublicKey(browserPrivateKey);
    final shared = await x25519SharedSecret(
      privateKey: browserPrivateKey,
      peerPublicKey: phoneEphPub,
    );
    Uint8List? key;
    try {
      key = await qrTransferKey(
        sharedSecret: shared,
        sid: sid,
        browserPub: browserPub,
        phoneEphPub: phoneEphPub,
      );
      return await open(
        key: key,
        nonce: nonce,
        ciphertext: ciphertext,
        aad: sid,
      );
    } finally {
      wipeAll([shared, key]);
    }
  }

  /// The byte string the phone signs to approve a QR login (161 bytes):
  /// `"leopard/qr-approve/v1" || sid || browser_pub || phone_eph_pub ||
  /// nonce || ciphertext`.
  static Uint8List qrApproveMessage({
    required Uint8List sid,
    required Uint8List browserPub,
    required Uint8List phoneEphPub,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) {
    checkSize(sid, sidSize, 'sid');
    checkSize(browserPub, x25519KeySize, 'browser_pub');
    checkSize(phoneEphPub, x25519KeySize, 'phone_eph_pub');
    checkSize(nonce, nonceSize, 'nonce');
    checkSize(ciphertext, qrCiphertextSize, 'QR ciphertext');
    return concatBytes([
      asciiBytes(labelQrApprove),
      sid,
      browserPub,
      phoneEphPub,
      nonce,
      ciphertext,
    ]);
  }

  /// The 6-digit code shown on both screens (§10.3): the first three bytes
  /// of `SHA256("leopard/verify/v1" || sid || browser_pub)` as a big-endian
  /// uint24, modulo 1 000 000, zero-padded.
  Future<String> verifyCode({
    required Uint8List sid,
    required Uint8List browserPub,
  }) async {
    checkSize(sid, sidSize, 'sid');
    checkSize(browserPub, x25519KeySize, 'browser_pub');
    final digest = await sha256(
      concatBytes([asciiBytes(labelVerify), sid, browserPub]),
    );
    final n = (digest[0] << 16) | (digest[1] << 8) | digest[2];
    return (n % 1000000).toString().padLeft(6, '0');
  }

  /// Phone side of QR login, steps 6 of §10.1: a fresh ephemeral key pair
  /// and nonce, VK encrypted for the browser, and the approval signed with
  /// the device key.
  ///
  /// The caller MUST first have taken [sid] and [browserPub] from the QR
  /// code itself, checked them against `GET /v1/qr/{sid}/details`, and had
  /// the user confirm the verification code.
  Future<QrApproval> approveQrLogin({
    required Uint8List vaultKey,
    required Uint8List deviceSeed,
    required Uint8List sid,
    required Uint8List browserPub,
  }) async {
    final ephemeral = await generateX25519KeyPair();
    try {
      final nonce = randomBytes(nonceSize);
      final ciphertext = await qrSealVaultKey(
        phoneEphPrivateKey: ephemeral.privateKey,
        browserPub: browserPub,
        sid: sid,
        nonce: nonce,
        vaultKey: vaultKey,
      );
      final signature = await ed25519Sign(
        seed: deviceSeed,
        message: qrApproveMessage(
          sid: sid,
          browserPub: browserPub,
          phoneEphPub: ephemeral.publicKey,
          nonce: nonce,
          ciphertext: ciphertext,
        ),
      );
      return QrApproval(
        phoneEphPub: ephemeral.publicKey,
        nonce: nonce,
        ciphertext: ciphertext,
        signature: signature,
      );
    } finally {
      ephemeral.destroy();
    }
  }

  // ---- Ed25519 device key and device login (§9) ----

  /// A fresh Ed25519 device key pair.
  Future<Ed25519KeyPair> generateEd25519KeyPair() async =>
      ed25519KeyPairFromSeed(randomBytes(ed25519SeedSize));

  /// The key pair for a stored 32-byte seed. The seed is copied.
  Future<Ed25519KeyPair> ed25519KeyPairFromSeed(Uint8List seed) async {
    checkSize(seed, ed25519SeedSize, 'Ed25519 seed');
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return Ed25519KeyPair(
      seed: Uint8List.fromList(seed),
      publicKey: Uint8List.fromList(publicKey.bytes),
    );
  }

  /// Pure Ed25519 (RFC 8032) signature; 64 bytes, deterministic.
  Future<Uint8List> ed25519Sign({
    required Uint8List seed,
    required List<int> message,
  }) async {
    checkSize(seed, ed25519SeedSize, 'Ed25519 seed');
    final keyPair = await _ed25519.newKeyPairFromSeed(seed);
    final signature = await _ed25519.sign(message, keyPair: keyPair);
    final bytes = Uint8List.fromList(signature.bytes);
    checkSize(bytes, ed25519SignatureSize, 'Ed25519 signature');
    return bytes;
  }

  /// Verifies an Ed25519 signature. Returns `false` (never throws) for a
  /// wrong signature, a wrong key or inputs of the wrong length.
  Future<bool> ed25519Verify({
    required Uint8List publicKey,
    required List<int> message,
    required Uint8List signature,
  }) async {
    if (publicKey.length != ed25519PublicKeySize ||
        signature.length != ed25519SignatureSize) {
      return false;
    }
    try {
      return await _ed25519.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      return false;
    }
  }

  /// What a device signs to log in (90 bytes):
  /// `"leopard/device-auth/v1" || device_id (36 ASCII bytes) || challenge`.
  static Uint8List deviceAuthMessage({
    required String deviceId,
    required Uint8List challenge,
  }) {
    final id = uuidAsciiBytes(deviceId, 'device id');
    checkSize(challenge, deviceChallengeSize, 'challenge');
    return concatBytes([asciiBytes(labelDeviceAuth), id, challenge]);
  }

  /// Signs a device-login challenge with the device key.
  Future<Uint8List> signDeviceAuth({
    required Uint8List deviceSeed,
    required String deviceId,
    required Uint8List challenge,
  }) async => ed25519Sign(
    seed: deviceSeed,
    message: deviceAuthMessage(deviceId: deviceId, challenge: challenge),
  );

  // ---- TOTP (§7) ----

  /// The RFC 6238 code (HMAC-SHA1, T0 = 0) for [unixSeconds].
  ///
  /// The server verifies the second factor; clients need this to show the
  /// current code for the vault's own TOTP secret during enrolment and for
  /// `totp` secrets stored in login items.
  Future<String> totpCode({
    required Uint8List secret,
    required int unixSeconds,
    int period = 30,
    int digits = 6,
  }) async {
    if (secret.isEmpty) {
      throw const InvalidSizeException('TOTP secret is empty');
    }
    if (unixSeconds < 0 || period < 1 || digits < 6 || digits > 8) {
      throw const InvalidSizeException('TOTP parameters out of range');
    }
    final step = unixSeconds ~/ period;
    final counter = Uint8List(8);
    ByteData.sublistView(counter)
      ..setUint32(0, step ~/ 0x100000000)
      ..setUint32(4, step % 0x100000000);
    final mac = await _hmacSha1.calculateMac(
      counter,
      secretKey: SecretKeyData(secret),
    );
    final h = mac.bytes;
    final offset = h[h.length - 1] & 0x0f;
    final binary =
        ((h[offset] & 0x7f) << 24) |
        (h[offset + 1] << 16) |
        (h[offset + 2] << 8) |
        h[offset + 3];
    var modulus = 1;
    for (var i = 0; i < digits; i++) {
      modulus *= 10;
    }
    return (binary % modulus).toString().padLeft(digits, '0');
  }

  /// The `otpauth://totp/...` URI (Base32 secret, SHA1, 6 digits, 30 s) to
  /// show as the enrolment QR code at setup. The URI contains the secret:
  /// show it once and do not log or store it.
  static String totpProvisioningUri({
    required Uint8List secret,
    required String accountName,
    String issuer = 'Leopard',
  }) {
    final label = Uri.encodeComponent('$issuer:$accountName');
    return 'otpauth://totp/$label'
        '?secret=${base32EncodeNoPad(secret)}'
        '&issuer=${Uri.encodeComponent(issuer)}'
        '&algorithm=SHA1&digits=6&period=30';
  }

  // ---- Setup (§12) ----

  /// Generates everything for a new vault (steps 1 to 4 of §12): VK,
  /// recovery key, salt, device key, TOTP secret, both wrapped keys and both
  /// verifiers. The KEK, recovery KEK and auth keys are wiped before this
  /// returns; [password] is the caller's to wipe.
  Future<VaultSetupMaterial> createVaultSetup({
    required Uint8List password,
    KdfParams params = KdfParams.v1,
  }) async {
    params.validate();
    final vaultKey = generateVaultKey();
    final recoveryKey = generateRecoveryKey();
    final salt = randomBytes(params.saltLength);
    final totpSecret = randomBytes(totpSecretSize);
    Uint8List? kek;
    Uint8List? rkKek;
    Uint8List? masterAuth;
    Uint8List? recoveryAuth;
    try {
      kek = await deriveKek(password: password, salt: salt, params: params);
      rkKek = await recoveryKek(recoveryKey);
      masterAuth = await masterAuthKey(kek);
      recoveryAuth = await recoveryAuthKey(recoveryKey);
      return VaultSetupMaterial(
        kdfParams: params,
        salt: salt,
        wrappedVkMaster: await wrapVaultKey(
          kek: kek,
          vaultKey: vaultKey,
          label: WrapLabel.master,
        ),
        wrappedVkRecovery: await wrapVaultKey(
          kek: rkKek,
          vaultKey: vaultKey,
          label: WrapLabel.recovery,
        ),
        masterAuthVerifier: await authVerifier(masterAuth),
        recoveryAuthVerifier: await authVerifier(recoveryAuth),
        totpSecret: totpSecret,
        deviceKey: await generateEd25519KeyPair(),
        vaultKey: vaultKey,
        recoveryKey: recoveryKey,
      );
    } finally {
      wipeAll([kek, rkKek, masterAuth, recoveryAuth]);
    }
  }

  static Uint8List _wrapAad(WrapLabel label) => asciiBytes(switch (label) {
    WrapLabel.master => infoWrapMaster,
    WrapLabel.recovery => infoWrapRecovery,
  });
}
