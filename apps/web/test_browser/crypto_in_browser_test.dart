// Runs in a real browser:
//
//   flutter test --platform chrome test_browser
//
// `leopard_core`'s own suite runs on the Dart VM, where `LeopardCrypto()`
// is pure Dart. In the web app the same constructor selects Web Crypto for
// AES-GCM, HKDF, HMAC, SHA-256 and X25519, and Argon2id is Dart compiled to
// JavaScript. This file checks that path against values copied from
// docs/test-vectors.json (a browser test cannot read the file), so the
// browser is known to produce the same bytes as the phone and the Go
// reference implementation.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_core/leopard_core.dart';

void main() {
  final crypto = LeopardCrypto();
  final vk = hexDecode(
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
  );

  test('item key (HKDF, empty salt)', () async {
    expect(
      hexEncode(await crypto.deriveItemKey(vk)),
      'cb681ef1c999f23f7999de55faf28af132e0ddc450bf82a53bc9f478011ce0a7',
    );
  });

  group('qr_transfer vector', () {
    final sid = hexDecode('707172737475767778797a7b7c7d7e7f');
    final browserPriv = hexDecode(
      '303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f',
    );
    final browserPub = hexDecode(
      '34e42d4af5ef94a07a3a84201b889d4cd1a743cb27b11b6a10438a8feb8e5847',
    );
    final phonePub = hexDecode(
      '392d174a38b3b1beafaf1fe824870841c5fa531bc6eafdb6402c124664488c1c',
    );
    final nonce = hexDecode('d0d1d2d3d4d5d6d7d8d9dadb');
    final ciphertext = hexDecode(
      '7f7cca4055e613f7118d687cbc6b9d1c06609ba4e5d3c787c49583fc742950c6'
      'd5a46a3fcc44c725caad6fc0f37f7e0a',
    );

    test('X25519 public key and shared secret', () async {
      expect(await crypto.x25519PublicKey(browserPriv), browserPub);
      expect(
        hexEncode(
          await crypto.x25519SharedSecret(
            privateKey: browserPriv,
            peerPublicKey: phonePub,
          ),
        ),
        'd800703cfb0fc9422762b8cf9b29c7211cb2ef6abac6a29d2df1de283c1a5a50',
      );
    });

    test('the browser opens the vault key the phone sealed', () async {
      final opened = await crypto.qrOpenVaultKey(
        browserPrivateKey: browserPriv,
        phoneEphPub: phonePub,
        sid: sid,
        nonce: nonce,
        ciphertext: ciphertext,
      );
      expect(opened, vk);
    });

    test('verification code and QR text', () async {
      expect(
        await crypto.verifyCode(sid: sid, browserPub: browserPub),
        '423932',
      );
      expect(
        QrUri(sid: sid, browserPub: browserPub).toString(),
        'leopard://qr?v=1&sid=cHFyc3R1dnd4eXp7fH1-fw'
        '&pk=NOQtSvXvlKB6OoQgG4idTNGnQ8snsRtqEEOKj-uOWEc',
      );
    });

    test('a low-order point from the "phone" is rejected', () async {
      await expectLater(
        crypto.x25519SharedSecret(
          privateKey: browserPriv,
          peerPublicKey: Uint8List(x25519KeySize),
        ),
        throwsA(isA<InvalidKeyException>()),
      );
    });
  });

  test('QR login round trip with fresh keys', () async {
    final sid = randomBytes(sidSize);
    final vaultKey = crypto.generateVaultKey();
    final browser = await crypto.generateX25519KeyPair();
    final approval = await crypto.approveQrLogin(
      vaultKey: vaultKey,
      deviceSeed: randomBytes(ed25519SeedSize),
      sid: sid,
      browserPub: browser.publicKey,
    );
    expect(
      await crypto.qrOpenVaultKey(
        browserPrivateKey: browser.privateKey,
        phoneEphPub: approval.phoneEphPub,
        sid: sid,
        nonce: approval.nonce,
        ciphertext: approval.ciphertext,
      ),
      vaultKey,
    );
    // Another session id is another key and another AAD.
    await expectLater(
      crypto.qrOpenVaultKey(
        browserPrivateKey: browser.privateKey,
        phoneEphPub: approval.phoneEphPub,
        sid: randomBytes(sidSize),
        nonce: approval.nonce,
        ciphertext: approval.ciphertext,
      ),
      throwsA(isA<DecryptException>()),
    );
  });

  test('items: AES-256-GCM with the id and version as AAD', () async {
    const id = '0f8fad5b-d9cb-469f-a165-70867728950e';
    final itemKey = hexDecode(
      'cb681ef1c999f23f7999de55faf28af132e0ddc450bf82a53bc9f478011ce0a7',
    );
    // Start of the vector's ciphertext: same key, nonce, AAD and plaintext
    // prefix must give the same bytes (GCM is a stream cipher).
    final sealed = await crypto.sealItem(
      itemKey: itemKey,
      nonce: hexDecode('a0a1a2a3a4a5a6a7a8a9aaab'),
      itemId: id,
      version: 7,
      plaintext: utf8.encode('{"type":"login","title":"Example"'),
    );
    expect(
      hexEncode(sealed.sublist(0, 32)),
      '07942b02891b652adfc97f93926214860c36fa6dad6ae2f1331a8703c1f98137',
    );

    final item = LoginItem(
      title: 'Example',
      username: 'aziz',
      password: 'correct horse battery staple',
      createdAt: DateTime.utc(2026, 11, 11, 10),
      updatedAt: DateTime.utc(2026, 11, 11, 10),
    );
    final fresh = await crypto.encryptItem(
      itemKey: itemKey,
      itemId: id,
      version: 3,
      plaintext: item.encode(),
    );
    final opened = VaultItem.decode(
      await crypto.openItem(
        itemKey: itemKey,
        nonce: fresh.nonce,
        itemId: id,
        version: 3,
        ciphertext: fresh.ciphertext,
      ),
    );
    expect((opened as LoginItem).password, 'correct horse battery staple');
    await expectLater(
      crypto.openItem(
        itemKey: itemKey,
        nonce: fresh.nonce,
        itemId: id,
        version: 4,
        ciphertext: fresh.ciphertext,
      ),
      throwsA(isA<DecryptException>()),
    );
  });

  test('TOTP (HMAC-SHA1)', () async {
    expect(
      await crypto.totpCode(
        secret: ascii.encode('12345678901234567890'),
        unixSeconds: 1111111109,
      ),
      '081804',
    );
  });

  test(
    'master password: Argon2id (64 MiB, 3 passes), auth key and unwrap',
    () async {
      final watch = Stopwatch()..start();
      final kek = await crypto.deriveKek(
        password: LeopardCrypto.passwordBytes(
          'correct horse battery staple — Ünïcödé ✓',
        ),
        salt: hexDecode('101112131415161718191a1b1c1d1e1f'),
      );
      watch.stop();
      // Shown in the CI log: how long the emergency login's slow step takes
      // in this browser.
      // ignore: avoid_print
      print('Argon2id in the browser: ${watch.elapsedMilliseconds} ms');
      expect(
        hexEncode(kek),
        'ec6b135398a0a6c45e550a7b066175f2da613676573fc57addd4448d319c2bee',
      );
      expect(
        hexEncode(await crypto.masterAuthKey(kek)),
        '0133d530c4ae4dd661c66e7ae40d5edc7560de71eaf7175178700485972930bb',
      );
      final wrapped = await crypto.wrapVaultKeyWithNonce(
        kek: kek,
        nonce: hexDecode('b0b1b2b3b4b5b6b7b8b9babb'),
        vaultKey: vk,
        label: WrapLabel.master,
      );
      expect(
        hexEncode(wrapped.sublist(0, 24)),
        'b0b1b2b3b4b5b6b7b8b9babb2b7d9b9d7e7a40c48faceb34',
      );
      expect(
        await crypto.unwrapVaultKey(
          kek: kek,
          wrapped: wrapped,
          label: WrapLabel.master,
        ),
        vk,
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
