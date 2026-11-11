// Conformance test: every primitive must reproduce docs/test-vectors.json
// byte for byte. The same file is checked by the Go reference
// implementation (backend/internal/crypto/vectors_test.go).
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:test/test.dart';

Uint8List unhex(Object? value) => hexDecode(value! as String);

Map<String, Object?> section(Map<String, Object?> vectors, String name) =>
    vectors[name]! as Map<String, Object?>;

void main() {
  // `dart test` runs with the package root as the working directory.
  final file = File('../../docs/test-vectors.json');
  final vectors = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  // The pure-Dart implementation, explicitly: this is the code path that
  // runs when no platform implementation is injected.
  final crypto = LeopardCrypto(cryptography: DartCryptography());

  test('vector file is version 1 and has every expected section', () {
    expect(vectors['version'], 1);
    expect(
      vectors.keys.where((k) => !k.startsWith('_') && k != 'version').toSet(),
      {
        'device_auth',
        'encoding',
        'item_encryption',
        'item_key',
        'master_password',
        'qr_transfer',
        'recovery_key',
        'totp',
      },
      reason:
          'a section was added to or removed from the vectors; '
          'update this test so nothing goes unchecked',
    );
  });

  group('encoding', () {
    final v = section(vectors, 'encoding');

    test('base64url without padding', () {
      final bytes = unhex(v['bytes_hex']);
      expect(base64UrlEncodeNoPad(bytes), v['base64url']);
      expect(base64UrlDecodeNoPad(v['base64url']! as String), bytes);
      final vk = unhex(v['vk_hex']);
      expect(base64UrlEncodeNoPad(vk), v['vk_base64url']);
      expect(base64UrlDecodeNoPad(v['vk_base64url']! as String), vk);
    });

    test('SHA-256', () async {
      expect(
        hexEncode(await crypto.sha256(ascii.encode('abc'))),
        v['sha256_abc_hex'],
      );
    });
  });

  group('item_key', () {
    final v = section(vectors, 'item_key');

    test('label and empty salt', () {
      expect(v['info'], infoItem);
      expect(v['salt_hex'], '');
    });

    test('HKDF with empty salt', () async {
      final key = await crypto.deriveItemKey(unhex(v['vk_hex']));
      expect(hexEncode(key), v['item_key_hex']);
    });
  });

  group('item_encryption', () {
    final v = section(vectors, 'item_encryption');
    final itemKey = unhex(v['item_key_hex']);
    final nonce = unhex(v['nonce_hex']);
    final itemId = v['item_id']! as String;
    final version = v['version']! as int;
    final plaintext = utf8.encode(v['plaintext_utf8']! as String);

    test('AAD layout', () {
      final aad = LeopardCrypto.itemAad(itemId, version);
      expect(aad, hasLength(44));
      expect(hexEncode(aad), v['aad_hex']);
    });

    test('seal', () async {
      final ciphertext = await crypto.sealItem(
        itemKey: itemKey,
        nonce: nonce,
        itemId: itemId,
        version: version,
        plaintext: plaintext,
      );
      expect(ciphertext, hasLength(plaintext.length + tagSize));
      expect(hexEncode(ciphertext), v['ciphertext_hex']);
    });

    test('open', () async {
      final opened = await crypto.openItem(
        itemKey: itemKey,
        nonce: nonce,
        itemId: itemId,
        version: version,
        ciphertext: unhex(v['ciphertext_hex']),
      );
      expect(utf8.decode(opened), v['plaintext_utf8']);
    });
  });

  group('master_password', () {
    final v = section(vectors, 'master_password');
    final vk = unhex(v['vk_hex']);
    late final Uint8List kek;

    setUpAll(() async {
      final params = KdfParams.fromJson(
        v['kdf_params']! as Map<String, Object?>,
      );
      expect(params, KdfParams.v1);
      kek = await crypto.deriveKek(
        password: LeopardCrypto.passwordBytes(v['password_utf8']! as String),
        salt: unhex(v['salt_hex']),
        params: params,
      );
    });

    test('labels', () {
      expect(v['auth_info'], infoAuthMaster);
      expect(v['wrap_aad'], infoWrapMaster);
    });

    test('UTF-8 encoding of a non-ASCII password', () {
      expect(
        hexEncode(LeopardCrypto.passwordBytes(v['password_utf8']! as String)),
        v['password_utf8_hex'],
      );
    });

    test('the vector password is already NFC, so normalising is a no-op', () {
      final password = v['password_utf8']! as String;
      expect(password.codeUnits.any((c) => c > 0x7f), isTrue);
      expect(LeopardCrypto.normalizePassword(password), password);
      expect(
        hexEncode(utf8.encode(password)),
        v['password_utf8_hex'],
        reason: 'raw UTF-8 and NFC UTF-8 must agree for the vector input',
      );
    });

    test('KDF parameters round-trip through JSON', () {
      expect(KdfParams.v1.toJson(), v['kdf_params']);
    });

    test('Argon2id KEK', () {
      expect(hexEncode(kek), v['kek_hex']);
    });

    test('wrap VK', () async {
      final wrapped = await crypto.wrapVaultKeyWithNonce(
        kek: kek,
        nonce: unhex(v['wrap_nonce_hex']),
        vaultKey: vk,
        label: WrapLabel.master,
      );
      expect(wrapped, hasLength(wrappedVkSize));
      expect(hexEncode(wrapped), v['wrapped_vk_master_hex']);
    });

    test('unwrap VK', () async {
      final unwrapped = await crypto.unwrapVaultKey(
        kek: kek,
        wrapped: unhex(v['wrapped_vk_master_hex']),
        label: WrapLabel.master,
      );
      expect(unwrapped, vk);
    });

    test('auth key and verifier', () async {
      final authKey = await crypto.masterAuthKey(kek);
      expect(hexEncode(authKey), v['auth_key_hex']);
      expect(
        hexEncode(await crypto.authVerifier(authKey)),
        v['auth_verifier_hex'],
      );
    });
  });

  group('recovery_key', () {
    final v = section(vectors, 'recovery_key');
    final rk = unhex(v['rk_hex']);
    final vk = unhex(v['vk_hex']);

    test('labels', () {
      expect(v['kek_info'], infoWrapRecovery);
      expect(v['wrap_aad'], infoWrapRecovery);
      expect(v['auth_info'], infoAuthRecovery);
    });

    test('display format', () {
      expect(formatRecoveryKey(rk), v['display']);
      expect(parseRecoveryKey(v['display']! as String), rk);
    });

    test('recovery KEK', () async {
      expect(hexEncode(await crypto.recoveryKek(rk)), v['kek_hex']);
    });

    test('wrap and unwrap VK', () async {
      final kek = unhex(v['kek_hex']);
      final wrapped = await crypto.wrapVaultKeyWithNonce(
        kek: kek,
        nonce: unhex(v['wrap_nonce_hex']),
        vaultKey: vk,
        label: WrapLabel.recovery,
      );
      expect(hexEncode(wrapped), v['wrapped_vk_recovery_hex']);
      final unwrapped = await crypto.unwrapVaultKey(
        kek: kek,
        wrapped: unhex(v['wrapped_vk_recovery_hex']),
        label: WrapLabel.recovery,
      );
      expect(unwrapped, vk);
    });

    test('auth key and verifier', () async {
      final authKey = await crypto.recoveryAuthKey(rk);
      expect(hexEncode(authKey), v['auth_key_hex']);
      expect(
        hexEncode(await crypto.authVerifier(authKey)),
        v['auth_verifier_hex'],
      );
    });
  });

  group('qr_transfer', () {
    final v = section(vectors, 'qr_transfer');
    final sid = unhex(v['sid_hex']);
    final browserPriv = unhex(v['browser_priv_hex']);
    final browserPub = unhex(v['browser_pub_hex']);
    final phonePriv = unhex(v['phone_eph_priv_hex']);
    final phonePub = unhex(v['phone_eph_pub_hex']);
    final nonce = unhex(v['nonce_hex']);
    final vk = unhex(v['vk_hex']);
    final ciphertext = unhex(v['ciphertext_hex']);

    test('X25519 public keys', () async {
      expect(
        hexEncode(await crypto.x25519PublicKey(browserPriv)),
        v['browser_pub_hex'],
      );
      expect(
        hexEncode(await crypto.x25519PublicKey(phonePriv)),
        v['phone_eph_pub_hex'],
      );
    });

    test('X25519 shared secret, from both sides', () async {
      final fromPhone = await crypto.x25519SharedSecret(
        privateKey: phonePriv,
        peerPublicKey: browserPub,
      );
      final fromBrowser = await crypto.x25519SharedSecret(
        privateKey: browserPriv,
        peerPublicKey: phonePub,
      );
      expect(hexEncode(fromPhone), v['shared_secret_hex']);
      expect(hexEncode(fromBrowser), v['shared_secret_hex']);
    });

    test('HKDF salt, info and transfer key', () async {
      expect(v['hkdf_salt_hex'], v['sid_hex']);
      expect(
        hexEncode([...ascii.encode(infoQr), ...browserPub, ...phonePub]),
        v['hkdf_info_hex'],
      );
      final key = await crypto.qrTransferKey(
        sharedSecret: unhex(v['shared_secret_hex']),
        sid: sid,
        browserPub: browserPub,
        phoneEphPub: phonePub,
      );
      expect(hexEncode(key), v['transfer_key_hex']);
    });

    test('seal VK (phone side)', () async {
      expect(v['aad_hex'], v['sid_hex']);
      final sealed = await crypto.qrSealVaultKey(
        phoneEphPrivateKey: phonePriv,
        browserPub: browserPub,
        sid: sid,
        nonce: nonce,
        vaultKey: vk,
      );
      expect(sealed, hasLength(qrCiphertextSize));
      expect(hexEncode(sealed), v['ciphertext_hex']);
    });

    test('open VK (browser side)', () async {
      final opened = await crypto.qrOpenVaultKey(
        browserPrivateKey: browserPriv,
        phoneEphPub: phonePub,
        sid: sid,
        nonce: nonce,
        ciphertext: ciphertext,
      );
      expect(opened, vk);
    });

    test('approval message and Ed25519 signature', () async {
      final message = LeopardCrypto.qrApproveMessage(
        sid: sid,
        browserPub: browserPub,
        phoneEphPub: phonePub,
        nonce: nonce,
        ciphertext: ciphertext,
      );
      expect(message, hasLength(161));
      expect(hexEncode(message), v['approve_message_hex']);

      final device = await crypto.ed25519KeyPairFromSeed(
        unhex(v['device_seed_hex']),
      );
      expect(hexEncode(device.publicKey), v['device_pub_hex']);
      final signature = await crypto.ed25519Sign(
        seed: device.seed,
        message: message,
      );
      expect(hexEncode(signature), v['approve_signature_hex']);
      expect(
        await crypto.ed25519Verify(
          publicKey: unhex(v['device_pub_hex']),
          message: message,
          signature: unhex(v['approve_signature_hex']),
        ),
        isTrue,
      );
    });

    test('verification code', () async {
      expect(
        await crypto.verifyCode(sid: sid, browserPub: browserPub),
        v['verify_code'],
      );
    });

    test('QR URI', () {
      expect(base64UrlEncodeNoPad(sid), v['sid_base64url']);
      final uri = QrUri(sid: sid, browserPub: browserPub);
      expect(uri.toString(), v['qr_uri']);
      expect(uri.sidBase64, v['sid_base64url']);
      final parsed = QrUri.parse(v['qr_uri']! as String);
      expect(parsed.sid, sid);
      expect(parsed.browserPub, browserPub);
    });
  });

  group('device_auth', () {
    final v = section(vectors, 'device_auth');
    final challenge = unhex(v['challenge_hex']);
    final deviceId = v['device_id']! as String;

    test('message', () {
      final message = LeopardCrypto.deviceAuthMessage(
        deviceId: deviceId,
        challenge: challenge,
      );
      expect(message, hasLength(90));
      expect(hexEncode(message), v['message_hex']);
    });

    test('signature', () async {
      final device = await crypto.ed25519KeyPairFromSeed(
        unhex(v['device_seed_hex']),
      );
      expect(hexEncode(device.publicKey), v['device_pub_hex']);
      final signature = await crypto.signDeviceAuth(
        deviceSeed: device.seed,
        deviceId: deviceId,
        challenge: challenge,
      );
      expect(hexEncode(signature), v['signature_hex']);
      expect(
        await crypto.ed25519Verify(
          publicKey: device.publicKey,
          message: unhex(v['message_hex']),
          signature: signature,
        ),
        isTrue,
      );
    });
  });

  group('totp', () {
    final v = section(vectors, 'totp');

    test('parameters', () {
      expect(v['algorithm'], 'SHA1');
      expect(v['digits'], 6);
      expect(v['period'], 30);
      expect(
        hexEncode(ascii.encode(v['secret_ascii']! as String)),
        v['secret_hex'],
      );
    });

    test('RFC 6238 codes', () async {
      final secret = unhex(v['secret_hex']);
      final cases = (v['cases']! as List<Object?>).cast<Map<String, Object?>>();
      expect(cases, isNotEmpty);
      for (final c in cases) {
        final time = c['unix_time']! as int;
        expect(time ~/ 30, c['step']);
        expect(
          await crypto.totpCode(secret: secret, unixSeconds: time),
          c['code'],
          reason: 'unix_time $time',
        );
      }
    });
  });
}
