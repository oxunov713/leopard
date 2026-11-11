// Round-trip and negative tests for the crypto layer. Byte-exact
// conformance with the Go implementation is in test_vectors_test.dart.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:test/test.dart';

const itemId = '0f8fad5b-d9cb-469f-a165-70867728950e';
const otherItemId = '9b2e7f10-3c4d-4e5f-8a6b-7c8d9e0f1a2b';
const deviceId = '7c9e6679-7425-40de-944b-e07fc1f90ae7';

final throwsDecrypt = throwsA(isA<DecryptException>());
final throwsSize = throwsA(isA<InvalidSizeException>());
final throwsFormat = throwsA(isA<InvalidFormatException>());

Uint8List flipBit(Uint8List bytes, int index) =>
    Uint8List.fromList(bytes)..[index] ^= 0x01;

void main() {
  final crypto = LeopardCrypto(cryptography: DartCryptography());

  group('base64url without padding', () {
    test('round-trips every length from 0 to 64', () {
      for (var n = 0; n <= 64; n++) {
        final bytes = randomBytes(n);
        final text = base64UrlEncodeNoPad(bytes);
        expect(text, isNot(contains('=')));
        expect(text, base64Url.encode(bytes).replaceAll('=', ''));
        expect(base64UrlDecodeNoPad(text), bytes);
      }
    });

    test('rejects padding', () {
      expect(() => base64UrlDecodeNoPad('AA=='), throwsFormat);
      expect(() => base64UrlDecodeNoPad('AAA='), throwsFormat);
    });

    test('rejects the standard alphabet, whitespace and non-ASCII', () {
      expect(() => base64UrlDecodeNoPad('+___'), throwsFormat);
      expect(() => base64UrlDecodeNoPad('/___'), throwsFormat);
      expect(() => base64UrlDecodeNoPad('AA A'), throwsFormat);
      expect(() => base64UrlDecodeNoPad('AAAA\n'), throwsFormat);
      expect(() => base64UrlDecodeNoPad('AAAé'), throwsFormat);
    });

    test('rejects an impossible length', () {
      expect(() => base64UrlDecodeNoPad('A'), throwsFormat);
      expect(() => base64UrlDecodeNoPad('AAAAA'), throwsFormat);
    });

    test('rejects non-zero trailing bits', () {
      // "AA" is one zero byte; "AB" has a stray low bit.
      expect(base64UrlDecodeNoPad('AA'), [0]);
      expect(() => base64UrlDecodeNoPad('AB'), throwsFormat);
      expect(base64UrlDecodeNoPad('AAA'), [0, 0]);
      expect(() => base64UrlDecodeNoPad('AAB'), throwsFormat);
    });
  });

  group('UUID', () {
    test('canonical form only', () {
      expect(isCanonicalUuid(itemId), isTrue);
      expect(isCanonicalUuid(itemId.toUpperCase()), isFalse);
      expect(isCanonicalUuid(itemId.replaceAll('-', '')), isFalse);
      expect(isCanonicalUuid('${itemId}0'), isFalse);
      expect(isCanonicalUuid(itemId.replaceFirst('0', 'g')), isFalse);
      expect(isCanonicalUuid(''), isFalse);
    });

    test('newUuid is a canonical version 4 UUID', () {
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        final id = newUuid();
        expect(isCanonicalUuid(id), isTrue);
        expect(id[14], '4');
        expect('89ab'.contains(id[19]), isTrue);
        seen.add(id);
      }
      expect(seen, hasLength(200));
    });
  });

  group('wipe', () {
    test('zeroes the buffer and tolerates null', () {
      final secret = randomBytes(32);
      wipe(secret);
      expect(secret, everyElement(0));
      wipe(null);
      final a = randomBytes(8);
      final b = randomBytes(8);
      wipeAll([a, null, b]);
      expect([...a, ...b], everyElement(0));
    });

    test('constantTimeEquals', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
      expect(constantTimeEquals([], []), isTrue);
    });
  });

  group('items', () {
    late Uint8List itemKey;
    final plaintext = utf8.encode('{"v":1,"type":"secureNote"}');

    setUpAll(() async {
      itemKey = await crypto.deriveItemKey(crypto.generateVaultKey());
    });

    test('round-trip with a random nonce', () async {
      final sealed = await crypto.encryptItem(
        itemKey: itemKey,
        itemId: itemId,
        version: 1,
        plaintext: plaintext,
      );
      expect(sealed.nonce, hasLength(nonceSize));
      expect(sealed.ciphertext, hasLength(plaintext.length + tagSize));
      final opened = await crypto.openItem(
        itemKey: itemKey,
        nonce: sealed.nonce,
        itemId: itemId,
        version: 1,
        ciphertext: sealed.ciphertext,
      );
      expect(opened, plaintext);
    });

    test('empty and large plaintexts round-trip', () async {
      for (final size in [0, 1, 15, 16, 17, 4096, 100000]) {
        final data = randomBytes(size);
        final sealed = await crypto.encryptItem(
          itemKey: itemKey,
          itemId: itemId,
          version: 3,
          plaintext: data,
        );
        final opened = await crypto.openItem(
          itemKey: itemKey,
          nonce: sealed.nonce,
          itemId: itemId,
          version: 3,
          ciphertext: sealed.ciphertext,
        );
        expect(opened, data, reason: 'size $size');
      }
    });

    test('every encryption uses a fresh nonce', () async {
      final nonces = <String>{};
      for (var i = 0; i < 50; i++) {
        final sealed = await crypto.encryptItem(
          itemKey: itemKey,
          itemId: itemId,
          version: 1,
          plaintext: plaintext,
        );
        nonces.add(hexEncode(sealed.nonce));
      }
      expect(nonces, hasLength(50));
    });

    group('open fails for', () {
      late SealedItem sealed;

      setUpAll(() async {
        sealed = await crypto.encryptItem(
          itemKey: itemKey,
          itemId: itemId,
          version: 7,
          plaintext: plaintext,
        );
      });

      Future<Uint8List> open({
        Uint8List? key,
        Uint8List? nonce,
        String id = itemId,
        int version = 7,
        Uint8List? ciphertext,
      }) => crypto.openItem(
        itemKey: key ?? itemKey,
        nonce: nonce ?? sealed.nonce,
        itemId: id,
        version: version,
        ciphertext: ciphertext ?? sealed.ciphertext,
      );

      test('nothing, as a control', () async {
        expect(await open(), plaintext);
      });

      test('a flipped bit anywhere in the ciphertext or tag', () async {
        for (var i = 0; i < sealed.ciphertext.length; i++) {
          await expectLater(
            open(ciphertext: flipBit(sealed.ciphertext, i)),
            throwsDecrypt,
            reason: 'byte $i',
          );
        }
      });

      test('a truncated or extended ciphertext', () async {
        final ct = sealed.ciphertext;
        await expectLater(
          open(ciphertext: Uint8List.sublistView(ct, 0, ct.length - 1)),
          throwsDecrypt,
        );
        await expectLater(
          open(ciphertext: Uint8List.fromList([...ct, 0])),
          throwsDecrypt,
        );
        await expectLater(open(ciphertext: Uint8List(15)), throwsSize);
      });

      test('a different nonce', () async {
        await expectLater(open(nonce: flipBit(sealed.nonce, 0)), throwsDecrypt);
      });

      test('a different key', () async {
        await expectLater(open(key: flipBit(itemKey, 31)), throwsDecrypt);
      });

      test('a different version (roll-back or roll-forward)', () async {
        await expectLater(open(version: 6), throwsDecrypt);
        await expectLater(open(version: 8), throwsDecrypt);
        await expectLater(open(version: 0), throwsDecrypt);
        // Same low 32 bits, different high half.
        await expectLater(open(version: 7 + 0x100000000), throwsDecrypt);
      });

      test('a different item id (swapped ciphertexts)', () async {
        await expectLater(open(id: otherItemId), throwsDecrypt);
      });
    });

    test('item AAD rejects non-canonical ids and bad versions', () {
      expect(
        () => LeopardCrypto.itemAad(itemId.toUpperCase(), 1),
        throwsFormat,
      );
      expect(() => LeopardCrypto.itemAad('not-a-uuid', 1), throwsFormat);
      expect(() => LeopardCrypto.itemAad(itemId, -1), throwsSize);
      expect(
        () => LeopardCrypto.itemAad(itemId, maxItemVersion + 1),
        throwsSize,
      );
    });

    test('item AAD encodes versions above 32 bits big-endian', () {
      final aad = LeopardCrypto.itemAad(itemId, 0x0102030405060708 >> 12);
      // 0x0000102030405060
      expect(hexEncode(aad.sublist(36)), '0000102030405060');
      expect(
        hexEncode(LeopardCrypto.itemAad(itemId, maxItemVersion).sublist(36)),
        '001fffffffffffff',
      );
    });

    test('wrong key and nonce sizes are rejected before any crypto', () {
      expect(
        crypto.seal(
          key: Uint8List(31),
          nonce: Uint8List(12),
          plaintext: const [],
          aad: const [],
        ),
        throwsSize,
      );
      expect(
        crypto.seal(
          key: Uint8List(32),
          nonce: Uint8List(11),
          plaintext: const [],
          aad: const [],
        ),
        throwsSize,
      );
      expect(crypto.deriveItemKey(Uint8List(16)), throwsSize);
    });
  });

  group('vault key wrapping', () {
    final vk = crypto.generateVaultKey();
    final kek = randomBytes(keySize);

    test('round-trips under both labels', () async {
      for (final label in WrapLabel.values) {
        final wrapped = await crypto.wrapVaultKey(
          kek: kek,
          vaultKey: vk,
          label: label,
        );
        expect(wrapped, hasLength(wrappedVkSize));
        expect(
          await crypto.unwrapVaultKey(kek: kek, wrapped: wrapped, label: label),
          vk,
        );
      }
    });

    test('a blob wrapped under one label does not open under the other', () {
      return Future.wait([
        for (final label in WrapLabel.values)
          () async {
            final other = label == WrapLabel.master
                ? WrapLabel.recovery
                : WrapLabel.master;
            final wrapped = await crypto.wrapVaultKey(
              kek: kek,
              vaultKey: vk,
              label: label,
            );
            await expectLater(
              crypto.unwrapVaultKey(kek: kek, wrapped: wrapped, label: other),
              throwsDecrypt,
            );
          }(),
      ]);
    });

    test('wrong KEK and tampering fail', () async {
      final wrapped = await crypto.wrapVaultKey(
        kek: kek,
        vaultKey: vk,
        label: WrapLabel.master,
      );
      await expectLater(
        crypto.unwrapVaultKey(
          kek: flipBit(kek, 0),
          wrapped: wrapped,
          label: WrapLabel.master,
        ),
        throwsDecrypt,
      );
      for (final i in [0, 11, 12, 43, 44, 59]) {
        await expectLater(
          crypto.unwrapVaultKey(
            kek: kek,
            wrapped: flipBit(wrapped, i),
            label: WrapLabel.master,
          ),
          throwsDecrypt,
          reason: 'byte $i',
        );
      }
    });

    test('wrong sizes are rejected', () {
      expect(
        crypto.unwrapVaultKey(
          kek: kek,
          wrapped: Uint8List(59),
          label: WrapLabel.master,
        ),
        throwsSize,
      );
      expect(
        crypto.wrapVaultKey(
          kek: kek,
          vaultKey: Uint8List(31),
          label: WrapLabel.master,
        ),
        throwsSize,
      );
    });
  });

  group('KDF parameters', () {
    KdfParams with_({
      String algorithm = 'argon2id',
      int version = 19,
      int memoryKib = 65536,
      int iterations = 3,
      int parallelism = 1,
      int keyLength = 32,
      int saltLength = 16,
    }) => KdfParams(
      algorithm: algorithm,
      version: version,
      memoryKib: memoryKib,
      iterations: iterations,
      parallelism: parallelism,
      keyLength: keyLength,
      saltLength: saltLength,
    );

    final throwsKdf = throwsA(isA<InvalidKdfParamsException>());

    test('v1 and the documented upper bounds are accepted', () {
      KdfParams.v1.validate();
      with_(memoryKib: 1048576, iterations: 16, parallelism: 4).validate();
    });

    test('anything weaker than v1 is refused (downgrade)', () {
      expect(() => with_(memoryKib: 65535).validate(), throwsKdf);
      expect(() => with_(memoryKib: 8).validate(), throwsKdf);
      expect(() => with_(iterations: 2).validate(), throwsKdf);
      expect(() => with_(iterations: 0).validate(), throwsKdf);
      expect(() => with_(parallelism: 0).validate(), throwsKdf);
      expect(() => with_(algorithm: 'argon2i').validate(), throwsKdf);
      expect(() => with_(algorithm: 'pbkdf2').validate(), throwsKdf);
      expect(() => with_(version: 16).validate(), throwsKdf);
      expect(() => with_(keyLength: 16).validate(), throwsKdf);
      expect(() => with_(saltLength: 8).validate(), throwsKdf);
    });

    test('absurdly large parameters are refused', () {
      expect(() => with_(memoryKib: 1048577).validate(), throwsKdf);
      expect(() => with_(iterations: 17).validate(), throwsKdf);
      expect(() => with_(parallelism: 5).validate(), throwsKdf);
      expect(() => with_(keyLength: 64).validate(), throwsKdf);
    });

    test('deriveKek validates before running', () {
      expect(
        crypto.deriveKek(
          password: utf8.encode('pw'),
          salt: Uint8List(16),
          params: with_(memoryKib: 1024),
        ),
        throwsKdf,
      );
      expect(
        crypto.deriveKek(password: utf8.encode('pw'), salt: Uint8List(15)),
        throwsSize,
      );
    });

    test('fromJson requires every field with the right type', () {
      final good = KdfParams.v1.toJson();
      expect(KdfParams.fromJson(good), KdfParams.v1);
      for (final key in good.keys) {
        expect(
          () => KdfParams.fromJson({...good}..remove(key)),
          throwsKdf,
          reason: 'missing $key',
        );
      }
      expect(() => KdfParams.fromJson({...good, 't': '3'}), throwsKdf);
      expect(() => KdfParams.fromJson({...good, 'm_kib': 65536.5}), throwsKdf);
      expect(() => KdfParams.fromJson({...good, 'alg': 1}), throwsKdf);
    });
  });

  group('recovery key', () {
    test('format and parse round-trip', () {
      for (var i = 0; i < 200; i++) {
        final rk = crypto.generateRecoveryKey();
        final text = formatRecoveryKey(rk);
        expect(text, matches(RegExp(r'^([A-Z2-7]{4}-){6}[A-Z2-7]{2}$')));
        expect(parseRecoveryKey(text), rk);
      }
    });

    test('parse ignores dashes, whitespace and case', () {
      final rk = hexDecode('202122232425262728292a2b2c2d2e2f');
      const display = 'EAQS-EIZE-EUTC-OKBJ-FIVS-YLJO-F4';
      expect(parseRecoveryKey(display), rk);
      expect(parseRecoveryKey(display.toLowerCase()), rk);
      expect(parseRecoveryKey(display.replaceAll('-', '')), rk);
      expect(parseRecoveryKey('  eaqs eize\teutc\nokbj-fivs--yljo f4\r\n'), rk);
    });

    test('malformed keys are rejected', () {
      const display = 'EAQS-EIZE-EUTC-OKBJ-FIVS-YLJO-F4';
      // Too short, too long, empty.
      expect(() => parseRecoveryKey(''), throwsFormat);
      expect(
        () => parseRecoveryKey(display.substring(0, display.length - 1)),
        throwsFormat,
      );
      expect(() => parseRecoveryKey('${display}A'), throwsFormat);
      // Characters outside the Base32 alphabet: 0, 1, 8, 9 and punctuation.
      for (final bad in ['0', '1', '8', '9', '_', '=', 'é']) {
        expect(
          () => parseRecoveryKey(display.replaceFirst('E', bad)),
          throwsFormat,
          reason: 'character $bad',
        );
      }
      // Non-ASCII whitespace is not ignored.
      expect(() => parseRecoveryKey('$display '), throwsFormat);
    });

    test('non-zero surplus bits are rejected (strict re-encode check)', () {
      // 26 characters carry 130 bits; the last character may only be one of
      // A, E, I, M, Q, U, Y, 4 (low two bits zero). "F4" -> "F5" sets one.
      const prefix = 'EAQS-EIZE-EUTC-OKBJ-FIVS-YLJO-F';
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
      for (var i = 0; i < alphabet.length; i++) {
        final text = '$prefix${alphabet[i]}';
        if (i % 4 == 0) {
          expect(formatRecoveryKey(parseRecoveryKey(text)), text);
        } else {
          expect(
            () => parseRecoveryKey(text),
            throwsFormat,
            reason: 'last character ${alphabet[i]}',
          );
        }
      }
    });

    test('format requires 16 bytes', () {
      expect(() => formatRecoveryKey(Uint8List(15)), throwsSize);
      expect(() => formatRecoveryKey(Uint8List(17)), throwsSize);
    });

    test('KEK and auth key are distinct and need a 16-byte key', () async {
      final rk = crypto.generateRecoveryKey();
      final kek = await crypto.recoveryKek(rk);
      final auth = await crypto.recoveryAuthKey(rk);
      expect(kek, isNot(auth));
      expect(crypto.recoveryKek(Uint8List(32)), throwsSize);
      expect(crypto.recoveryAuthKey(Uint8List(15)), throwsSize);
    });
  });

  group('X25519', () {
    test('both sides agree', () async {
      final a = await crypto.generateX25519KeyPair();
      final b = await crypto.generateX25519KeyPair();
      expect(a.publicKey, isNot(b.publicKey));
      expect(
        await crypto.x25519SharedSecret(
          privateKey: a.privateKey,
          peerPublicKey: b.publicKey,
        ),
        await crypto.x25519SharedSecret(
          privateKey: b.privateKey,
          peerPublicKey: a.publicKey,
        ),
      );
    });

    test('RFC 7748 section 6.1 vector', () async {
      final alicePriv = hexDecode(
        '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a',
      );
      final bobPub = hexDecode(
        'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f',
      );
      expect(
        hexEncode(await crypto.x25519PublicKey(alicePriv)),
        '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a',
      );
      expect(
        hexEncode(
          await crypto.x25519SharedSecret(
            privateKey: alicePriv,
            peerPublicKey: bobPub,
          ),
        ),
        '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742',
      );
    });

    test('low-order peer keys (all-zero shared secret) are rejected', () async {
      final priv = randomBytes(32);
      final lowOrder = [
        // 0, 1, and the order-8 point from RFC 7748 / libsodium's list.
        '0000000000000000000000000000000000000000000000000000000000000000',
        '0100000000000000000000000000000000000000000000000000000000000000',
        'e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800',
        '5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157',
        // p - 1, p, p + 1 (non-canonical encodings of low-order points).
        'ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
        'edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
        'eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
      ];
      for (final hex in lowOrder) {
        await expectLater(
          crypto.x25519SharedSecret(
            privateKey: priv,
            peerPublicKey: hexDecode(hex),
          ),
          throwsA(isA<InvalidKeyException>()),
          reason: hex,
        );
      }
    });

    test('wrong sizes are rejected', () {
      expect(crypto.x25519PublicKey(Uint8List(31)), throwsSize);
      expect(
        crypto.x25519SharedSecret(
          privateKey: Uint8List(32),
          peerPublicKey: Uint8List(33),
        ),
        throwsSize,
      );
    });
  });

  group('QR transfer', () {
    final vk = crypto.generateVaultKey();
    final sid = randomBytes(sidSize);
    late X25519KeyPair browser;
    late Ed25519KeyPair device;
    late QrApproval approval;

    setUpAll(() async {
      browser = await crypto.generateX25519KeyPair();
      device = await crypto.generateEd25519KeyPair();
      approval = await crypto.approveQrLogin(
        vaultKey: vk,
        deviceSeed: device.seed,
        sid: sid,
        browserPub: browser.publicKey,
      );
    });

    Future<Uint8List> open({
      Uint8List? browserPrivateKey,
      Uint8List? phoneEphPub,
      Uint8List? sessionId,
      Uint8List? nonce,
      Uint8List? ciphertext,
    }) => crypto.qrOpenVaultKey(
      browserPrivateKey: browserPrivateKey ?? browser.privateKey,
      phoneEphPub: phoneEphPub ?? approval.phoneEphPub,
      sid: sessionId ?? sid,
      nonce: nonce ?? approval.nonce,
      ciphertext: ciphertext ?? approval.ciphertext,
    );

    test('the browser recovers VK', () async {
      expect(approval.phoneEphPub, hasLength(x25519KeySize));
      expect(approval.nonce, hasLength(nonceSize));
      expect(approval.ciphertext, hasLength(qrCiphertextSize));
      expect(approval.signature, hasLength(ed25519SignatureSize));
      expect(await open(), vk);
    });

    test('every approval uses a fresh ephemeral key and nonce', () async {
      final second = await crypto.approveQrLogin(
        vaultKey: vk,
        deviceSeed: device.seed,
        sid: sid,
        browserPub: browser.publicKey,
      );
      expect(second.phoneEphPub, isNot(approval.phoneEphPub));
      expect(second.nonce, isNot(approval.nonce));
      expect(second.ciphertext, isNot(approval.ciphertext));
    });

    test('the signature verifies over the canonical message', () async {
      final message = LeopardCrypto.qrApproveMessage(
        sid: sid,
        browserPub: browser.publicKey,
        phoneEphPub: approval.phoneEphPub,
        nonce: approval.nonce,
        ciphertext: approval.ciphertext,
      );
      expect(
        await crypto.ed25519Verify(
          publicKey: device.publicKey,
          message: message,
          signature: approval.signature,
        ),
        isTrue,
      );
    });

    test('a different session id fails (replay into another session)', () {
      expect(open(sessionId: flipBit(sid, 0)), throwsDecrypt);
    });

    test('a different browser key fails', () async {
      final other = await crypto.generateX25519KeyPair();
      await expectLater(
        open(browserPrivateKey: other.privateKey),
        throwsDecrypt,
      );
    });

    test('a substituted phone key fails', () async {
      final other = await crypto.generateX25519KeyPair();
      await expectLater(open(phoneEphPub: other.publicKey), throwsDecrypt);
    });

    test('tampered nonce or ciphertext fails', () async {
      await expectLater(open(nonce: flipBit(approval.nonce, 5)), throwsDecrypt);
      for (final i in [0, 31, 32, 47]) {
        await expectLater(
          open(ciphertext: flipBit(approval.ciphertext, i)),
          throwsDecrypt,
          reason: 'byte $i',
        );
      }
    });

    test('wrong sizes are rejected', () {
      expect(open(ciphertext: Uint8List(47)), throwsSize);
      expect(open(sessionId: Uint8List(15)), throwsSize);
      expect(open(nonce: Uint8List(13)), throwsSize);
      expect(
        () => LeopardCrypto.qrApproveMessage(
          sid: sid,
          browserPub: browser.publicKey,
          phoneEphPub: approval.phoneEphPub,
          nonce: approval.nonce,
          ciphertext: Uint8List(49),
        ),
        throwsSize,
      );
    });

    test('the transfer key depends on every input', () async {
      final shared = randomBytes(32);
      final phonePub = approval.phoneEphPub;
      Future<String> key({
        Uint8List? s,
        Uint8List? id,
        Uint8List? b,
        Uint8List? p,
      }) async => hexEncode(
        await crypto.qrTransferKey(
          sharedSecret: s ?? shared,
          sid: id ?? sid,
          browserPub: b ?? browser.publicKey,
          phoneEphPub: p ?? phonePub,
        ),
      );
      final keys = {
        await key(),
        await key(s: flipBit(shared, 0)),
        await key(id: flipBit(sid, 0)),
        await key(b: flipBit(browser.publicKey, 0)),
        await key(p: flipBit(phonePub, 0)),
        // Swapping the two public keys must not give the same key.
        await key(b: phonePub, p: browser.publicKey),
      };
      expect(keys, hasLength(6));
    });
  });

  group('verification code', () {
    test('is six digits and depends on sid and key', () async {
      final sid = randomBytes(sidSize);
      final pub = randomBytes(x25519KeySize);
      final code = await crypto.verifyCode(sid: sid, browserPub: pub);
      expect(code, matches(RegExp(r'^\d{6}$')));
      expect(await crypto.verifyCode(sid: sid, browserPub: pub), code);
      final codes = <String>{};
      for (var i = 0; i < 20; i++) {
        codes.add(
          await crypto.verifyCode(sid: randomBytes(sidSize), browserPub: pub),
        );
      }
      // 20 random codes colliding into one would be astronomically unlikely.
      expect(codes.length, greaterThan(1));
    });

    test('wrong sizes are rejected', () {
      expect(
        crypto.verifyCode(sid: Uint8List(15), browserPub: Uint8List(32)),
        throwsSize,
      );
      expect(
        crypto.verifyCode(sid: Uint8List(16), browserPub: Uint8List(31)),
        throwsSize,
      );
    });
  });

  group('QR URI', () {
    final sid = hexDecode('707172737475767778797a7b7c7d7e7f');
    final pub = hexDecode(
      '34e42d4af5ef94a07a3a84201b889d4cd1a743cb27b11b6a10438a8feb8e5847',
    );
    const text =
        'leopard://qr?v=1&sid=cHFyc3R1dnd4eXp7fH1-fw'
        '&pk=NOQtSvXvlKB6OoQgG4idTNGnQ8snsRtqEEOKj-uOWEc';

    test('build and parse round-trip', () {
      for (var i = 0; i < 50; i++) {
        final uri = QrUri(
          sid: randomBytes(sidSize),
          browserPub: randomBytes(x25519KeySize),
        );
        final parsed = QrUri.parse(uri.toString());
        expect(parsed.sid, uri.sid);
        expect(parsed.browserPub, uri.browserPub);
        expect(parsed.toString(), uri.toString());
      }
    });

    test('parameter order does not matter', () {
      final parsed = QrUri.parse(
        'leopard://qr?pk=NOQtSvXvlKB6OoQgG4idTNGnQ8snsRtqEEOKj-uOWEc'
        '&sid=cHFyc3R1dnd4eXp7fH1-fw&v=1',
      );
      expect(parsed.sid, sid);
      expect(parsed.browserPub, pub);
      expect(parsed.toString(), text);
    });

    test('malformed URIs are rejected', () {
      final bad = <String>[
        '',
        'https://example.com/?v=1',
        'LEOPARD://qr?v=1&sid=cHFyc3R1dnd4eXp7fH1-fw&pk=x',
        'leopard://login?v=1&sid=cHFyc3R1dnd4eXp7fH1-fw',
        text.replaceFirst('v=1', 'v=2'),
        text.replaceFirst('v=1&', ''),
        text.replaceFirst('&pk=', '&px='),
        '$text&extra=1',
        '$text&v=1',
        '$text=',
        '$text ',
        // sid of 15 bytes, pk of 31 bytes.
        text.replaceFirst('cHFyc3R1dnd4eXp7fH1-fw', 'cHFyc3R1dnd4eXp7fH1-'),
        text.substring(0, text.length - 2),
        // Padding and percent-encoding are not accepted.
        text.replaceFirst('-fw&', '-fw==&'),
        text.replaceFirst('fH1-fw', 'fH1%2Dfw'),
        // Non-zero trailing bits in sid.
        text.replaceFirst('-fw&', '-fx&'),
      ];
      for (final candidate in bad) {
        expect(() => QrUri.parse(candidate), throwsFormat, reason: candidate);
      }
    });

    test('constructor checks sizes', () {
      expect(() => QrUri(sid: Uint8List(15), browserPub: pub), throwsSize);
      expect(() => QrUri(sid: sid, browserPub: Uint8List(33)), throwsSize);
    });
  });

  group('Ed25519 and device auth', () {
    late Ed25519KeyPair device;
    final challenge = randomBytes(deviceChallengeSize);

    setUpAll(() async {
      device = await crypto.generateEd25519KeyPair();
    });

    test('sign and verify round-trip; signing is deterministic', () async {
      final signature = await crypto.signDeviceAuth(
        deviceSeed: device.seed,
        deviceId: deviceId,
        challenge: challenge,
      );
      final again = await crypto.signDeviceAuth(
        deviceSeed: device.seed,
        deviceId: deviceId,
        challenge: challenge,
      );
      expect(signature, again);
      final message = LeopardCrypto.deviceAuthMessage(
        deviceId: deviceId,
        challenge: challenge,
      );
      expect(
        await crypto.ed25519Verify(
          publicKey: device.publicKey,
          message: message,
          signature: signature,
        ),
        isTrue,
      );
    });

    test('wrong signature, message or key does not verify', () async {
      final message = LeopardCrypto.deviceAuthMessage(
        deviceId: deviceId,
        challenge: challenge,
      );
      final signature = await crypto.ed25519Sign(
        seed: device.seed,
        message: message,
      );
      Future<bool> verify({
        Uint8List? publicKey,
        Uint8List? msg,
        Uint8List? sig,
      }) => crypto.ed25519Verify(
        publicKey: publicKey ?? device.publicKey,
        message: msg ?? message,
        signature: sig ?? signature,
      );

      expect(await verify(), isTrue);
      for (final i in [0, 31, 32, 63]) {
        expect(await verify(sig: flipBit(signature, i)), isFalse);
      }
      expect(await verify(msg: flipBit(message, 0)), isFalse);
      expect(await verify(msg: flipBit(message, 89)), isFalse);
      // A signature for another device id or challenge.
      expect(
        await verify(
          msg: LeopardCrypto.deviceAuthMessage(
            deviceId: otherItemId,
            challenge: challenge,
          ),
        ),
        isFalse,
      );
      final other = await crypto.generateEd25519KeyPair();
      expect(await verify(publicKey: other.publicKey), isFalse);
      // Wrong lengths and garbage never throw.
      expect(await verify(sig: Uint8List(63)), isFalse);
      expect(await verify(sig: Uint8List(64)), isFalse);
      expect(await verify(publicKey: Uint8List(31)), isFalse);
      expect(
        await verify(publicKey: Uint8List(32)..fillRange(0, 32, 0xff)),
        isFalse,
      );
    });

    test('a device-auth signature is not a valid QR approval', () async {
      // Domain separation: the two signed messages have different labels and
      // lengths, so one can never be replayed as the other.
      final auth = LeopardCrypto.deviceAuthMessage(
        deviceId: deviceId,
        challenge: challenge,
      );
      final approve = LeopardCrypto.qrApproveMessage(
        sid: Uint8List(16),
        browserPub: Uint8List(32),
        phoneEphPub: Uint8List(32),
        nonce: Uint8List(12),
        ciphertext: Uint8List(48),
      );
      expect(auth, hasLength(90));
      expect(approve, hasLength(161));
      expect(utf8.decode(auth.sublist(0, 22)), 'leopard/device-auth/v1');
      expect(utf8.decode(approve.sublist(0, 21)), 'leopard/qr-approve/v1');
    });

    test('device-auth message checks its inputs', () {
      expect(
        () => LeopardCrypto.deviceAuthMessage(
          deviceId: deviceId.toUpperCase(),
          challenge: challenge,
        ),
        throwsFormat,
      );
      expect(
        () => LeopardCrypto.deviceAuthMessage(
          deviceId: deviceId,
          challenge: Uint8List(31),
        ),
        throwsSize,
      );
    });

    test('destroy wipes the private halves', () async {
      final ed = await crypto.generateEd25519KeyPair();
      final x = await crypto.generateX25519KeyPair();
      ed.destroy();
      x.destroy();
      expect(ed.seed, everyElement(0));
      expect(x.privateKey, everyElement(0));
    });
  });

  group('setup', () {
    test('everything unwraps and verifies end to end', () async {
      final password = LeopardCrypto.passwordBytes('correct horse battery');
      final setup = await crypto.createVaultSetup(password: password);

      expect(setup.kdfParams, KdfParams.v1);
      expect(setup.salt, hasLength(saltSize));
      expect(setup.vaultKey, hasLength(keySize));
      expect(setup.recoveryKey, hasLength(recoveryKeySize));
      expect(setup.totpSecret, hasLength(totpSecretSize));
      expect(setup.wrappedVkMaster, hasLength(wrappedVkSize));
      expect(setup.wrappedVkRecovery, hasLength(wrappedVkSize));

      // Master path.
      final kek = await crypto.deriveKek(password: password, salt: setup.salt);
      expect(
        await crypto.unwrapVaultKey(
          kek: kek,
          wrapped: setup.wrappedVkMaster,
          label: WrapLabel.master,
        ),
        setup.vaultKey,
      );
      expect(
        await crypto.authVerifier(await crypto.masterAuthKey(kek)),
        setup.masterAuthVerifier,
      );

      // Recovery path, through the display format.
      final typed = formatRecoveryKey(setup.recoveryKey).toLowerCase();
      final rk = parseRecoveryKey(typed);
      expect(
        await crypto.unwrapVaultKey(
          kek: await crypto.recoveryKek(rk),
          wrapped: setup.wrappedVkRecovery,
          label: WrapLabel.recovery,
        ),
        setup.vaultKey,
      );
      expect(
        await crypto.authVerifier(await crypto.recoveryAuthKey(rk)),
        setup.recoveryAuthVerifier,
      );

      // A wrong password derives a KEK that does not unwrap.
      final wrong = await crypto.deriveKek(
        password: LeopardCrypto.passwordBytes('correct horse batterz'),
        salt: setup.salt,
      );
      await expectLater(
        crypto.unwrapVaultKey(
          kek: wrong,
          wrapped: setup.wrappedVkMaster,
          label: WrapLabel.master,
        ),
        throwsDecrypt,
      );

      setup.destroy();
      expect(setup.vaultKey, everyElement(0));
      expect(setup.recoveryKey, everyElement(0));
      expect(setup.totpSecret, everyElement(0));
      expect(setup.deviceKey.seed, everyElement(0));
    });
  });

  group('TOTP', () {
    test('provisioning URI', () {
      final uri = Uri.parse(
        LeopardCrypto.totpProvisioningUri(
          secret: Uint8List.fromList(ascii.encode('12345678901234567890')),
          accountName: 'my vault',
        ),
      );
      expect(uri.scheme, 'otpauth');
      expect(uri.host, 'totp');
      expect(uri.pathSegments.single, 'Leopard:my vault');
      expect(uri.queryParameters, {
        'secret': 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
        'issuer': 'Leopard',
        'algorithm': 'SHA1',
        'digits': '6',
        'period': '30',
      });
    });

    test('bad parameters are rejected', () {
      expect(crypto.totpCode(secret: Uint8List(0), unixSeconds: 0), throwsSize);
      expect(
        crypto.totpCode(secret: Uint8List(20), unixSeconds: -1),
        throwsSize,
      );
    });
  });

  group('exceptions', () {
    test('messages are fixed strings without secret material', () {
      expect(const DecryptException().toString(), contains('decryption'));
      try {
        parseRecoveryKey('SECRETSECRETSECRETSECRET01');
        fail('should have thrown');
      } on InvalidFormatException catch (e) {
        expect(e.toString(), isNot(contains('SECRET')));
      }
    });
  });
}
