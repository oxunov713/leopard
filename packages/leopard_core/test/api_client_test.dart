// API client tests against an in-memory server (MockClient), with real
// cryptography on both sides. Covers the full QR login from the browser's
// and the phone's point of view, plus every other endpoint and the error
// mapping.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

final baseUrl = Uri.parse('https://vault.test');
const password = 'correct horse battery staple — Ünïcödé ✓';

final crypto = LeopardCrypto(cryptography: DartCryptography());

/// The phone after setup and device login.
class Phone {
  Phone(this.api, this.setup, this.deviceId);

  final LeopardApiClient api;
  final VaultSetupMaterial setup;
  final String deviceId;

  Uint8List get vaultKey => setup.vaultKey;
}

// One Argon2id run shared by every test: setup material is immutable here.
late final VaultSetupMaterial sharedSetup;

Future<void> deviceLogin(
  LeopardApiClient api,
  String deviceId,
  Uint8List seed,
) async {
  final challenge = await api.deviceChallenge(deviceId);
  await api.deviceVerify(
    deviceId: deviceId,
    nonce: challenge.nonce,
    signature: await crypto.signDeviceAuth(
      deviceSeed: seed,
      deviceId: deviceId,
      challenge: challenge.nonce,
    ),
  );
}

Future<Phone> setUpPhone(FakeServer server) async {
  final api = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
  final result = await api.setup(material: sharedSetup, deviceLabel: 'Pixel');
  await deviceLogin(api, result.deviceId, sharedSetup.deviceKey.seed);
  return Phone(api, sharedSetup, result.deviceId);
}

http.Response jsonResponse(
  int status,
  Object? body, {
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

void main() {
  late FakeServer server;

  setUpAll(() async {
    sharedSetup = await crypto.createVaultSetup(
      password: LeopardCrypto.passwordBytes(password),
    );
  });

  setUp(() {
    server = FakeServer(crypto);
  });

  group('construction', () {
    test('https is required unless explicitly allowed', () {
      expect(
        () => LeopardApiClient(baseUrl: Uri.parse('http://vault.test')),
        throwsArgumentError,
      );
      expect(
        () => LeopardApiClient(baseUrl: Uri.parse('ftp://vault.test')),
        throwsArgumentError,
      );
      expect(
        () => LeopardApiClient(
          baseUrl: Uri.parse('ftp://vault.test'),
          allowInsecureHttp: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => LeopardApiClient(baseUrl: Uri.parse('https://vault.test/?a=1')),
        throwsArgumentError,
      );
      LeopardApiClient(
        baseUrl: Uri.parse('http://localhost:8080'),
        allowInsecureHttp: true,
      ).close();
    });

    test('a path prefix in the base URL is kept', () async {
      final seen = <Uri>[];
      final api = LeopardApiClient(
        baseUrl: Uri.parse('https://example.test/leopard/'),
        httpClient: MockClient((request) async {
          seen.add(request.url);
          return jsonResponse(200, {'status': 'ok'});
        }),
      );
      expect(await api.health(), isTrue);
      expect(seen.single.toString(), 'https://example.test/leopard/healthz');
    });
  });

  group('health', () {
    test('ok and unavailable', () async {
      final api = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
      expect(await api.health(), isTrue);
      server.intercept = (_) => jsonResponse(503, {'status': 'unavailable'});
      expect(await api.health(), isFalse);
    });
  });

  group('setup and device login', () {
    test('setup sends only public material', () async {
      final phone = await setUpPhone(server);
      expect(isCanonicalUuid(phone.deviceId), isTrue);

      final request = server.requests.first;
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/setup');
      expect(request.headers['content-type'], 'application/json');
      expect(request.headers.containsKey('authorization'), isFalse);
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body.keys.toSet(), {
        'kdf_params',
        'salt',
        'wrapped_vk_master',
        'wrapped_vk_recovery',
        'master_auth_verifier',
        'recovery_auth_verifier',
        'totp_secret',
        'device',
      });
      expect(body['kdf_params'], KdfParams.v1.toJson());
      expect(body['device'], {
        'label': 'Pixel',
        'ed25519_pub': base64UrlEncodeNoPad(sharedSetup.deviceKey.publicKey),
      });

      // Nothing secret may appear anywhere on the wire, in any encoding.
      final wire = server.requests.map((r) => r.body).join('\n');
      for (final secret in [
        sharedSetup.vaultKey,
        sharedSetup.recoveryKey,
        sharedSetup.deviceKey.seed,
      ]) {
        expect(wire, isNot(contains(base64UrlEncodeNoPad(secret))));
        expect(wire, isNot(contains(hexEncode(secret))));
      }
      expect(wire, isNot(contains(password)));
      expect(wire, isNot(contains(formatRecoveryKey(sharedSetup.recoveryKey))));
    });

    test('the setup token is sent as a header', () async {
      server.requiredSetupToken = 'let-me-in';
      final api = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
      await expectLater(
        api.setup(material: sharedSetup, deviceLabel: 'Pixel'),
        throwsA(
          isA<ForbiddenException>().having(
            (e) => e.code,
            'code',
            'setup_token_required',
          ),
        ),
      );
      await api.setup(
        material: sharedSetup,
        deviceLabel: 'Pixel',
        setupToken: 'let-me-in',
      );
      expect(
        server.requests.last.headers['x-leopard-setup-token'],
        'let-me-in',
      );
    });

    test('a second setup is a conflict and changes nothing', () async {
      final phone = await setUpPhone(server);
      await expectLater(
        phone.api.setup(material: sharedSetup, deviceLabel: 'Other'),
        throwsA(
          isA<ConflictException>()
              .having((e) => e.code, 'code', 'already_initialised')
              .having((e) => e.statusCode, 'status', 409)
              .having((e) => e.current, 'current', isNull)
              .having((e) => e.requestId, 'requestId', 'req-test'),
        ),
      );
      expect(server.devices, hasLength(1));
    });

    test('device login installs a mobile session', () async {
      final phone = await setUpPhone(server);
      expect(phone.api.hasSession, isTrue);
      final beat = await phone.api.heartbeat();
      expect(beat.kind, SessionKind.mobile);
      expect(beat.idleTimeoutSeconds, 86400);
      expect(
        server.requests.last.headers['authorization'],
        startsWith('Bearer '),
      );
    });

    test('a wrong signature fails and the nonce is single-use', () async {
      final phone = await setUpPhone(server);
      final api = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
      final other = await crypto.generateEd25519KeyPair();
      final challenge = await api.deviceChallenge(phone.deviceId);
      final failed = throwsA(
        isA<UnauthorizedException>()
            .having((e) => e.code, 'code', 'device_auth_failed')
            .having((e) => e.sessionEnded, 'sessionEnded', isFalse),
      );
      await expectLater(
        api.deviceVerify(
          deviceId: phone.deviceId,
          nonce: challenge.nonce,
          signature: await crypto.signDeviceAuth(
            deviceSeed: other.seed,
            deviceId: phone.deviceId,
            challenge: challenge.nonce,
          ),
        ),
        failed,
      );
      expect(api.hasSession, isFalse);
      // The right signature over the same, now consumed, nonce also fails.
      await expectLater(
        api.deviceVerify(
          deviceId: phone.deviceId,
          nonce: challenge.nonce,
          signature: await crypto.signDeviceAuth(
            deviceSeed: sharedSetup.deviceKey.seed,
            deviceId: phone.deviceId,
            challenge: challenge.nonce,
          ),
        ),
        failed,
      );
    });

    test('ids are validated before anything is sent', () async {
      final api = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
      expect(() => api.deviceChallenge('NOT-A-UUID'), throwsArgumentError);
      expect(server.requests, isEmpty);
    });
  });

  group('QR login', () {
    late Phone phone;
    late LeopardApiClient browser;
    late X25519KeyPair browserKey;

    setUp(() async {
      phone = await setUpPhone(server);
      browser = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
      browserKey = await crypto.generateX25519KeyPair();
    });

    /// Phone side, exactly as the app must do it: everything is taken from
    /// the scanned text, then checked against the server.
    Future<QrApproveResult> scanAndApprove(String qrText) async {
      final scanned = QrUri.parse(qrText);
      final details = await phone.api.qrDetails(scanned.sid);
      if (!constantTimeEquals(details.browserPub, scanned.browserPub)) {
        throw StateError('server reported a different browser key');
      }
      final code = await crypto.verifyCode(
        sid: scanned.sid,
        browserPub: scanned.browserPub,
      );
      if (code != details.verifyCode) {
        throw StateError('verification code mismatch');
      }
      final approval = await crypto.approveQrLogin(
        vaultKey: phone.vaultKey,
        deviceSeed: phone.setup.deviceKey.seed,
        sid: scanned.sid,
        browserPub: scanned.browserPub,
      );
      return phone.api.approveQr(sid: scanned.sid, approval: approval);
    }

    test('full flow: browser and phone end with the same vault key', () async {
      // Browser: create the request and show the QR code.
      final session = await browser.createQrSession(
        browserPub: browserKey.publicKey,
        clientInfo: {'platform': 'Linux', 'browser': 'Firefox'},
      );
      expect(browser.hasSession, isFalse);
      final qr = QrUri(sid: session.sid, browserPub: browserKey.publicKey);
      // The browser builds the QR text and code itself and cross-checks.
      expect(session.qrUri, qr.toString());
      final browserCode = await crypto.verifyCode(
        sid: session.sid,
        browserPub: browserKey.publicKey,
      );
      expect(session.verifyCode, browserCode);
      // The poll token is not in the QR code.
      expect(qr.toString(), isNot(contains(session.pollToken)));

      // Browser: still pending.
      final waiting = await browser.pollQrSession(
        sid: session.sid,
        pollToken: session.pollToken,
      );
      expect(waiting, isA<QrPollWaiting>());
      expect(waiting.status, QrStatus.pending);
      expect(
        server.requests.last.headers['x-leopard-poll-token'],
        session.pollToken,
      );
      expect(
        server.requests.last.headers.containsKey('authorization'),
        isFalse,
      );

      // Phone: details show the same code and the reported client info.
      final details = await phone.api.qrDetails(session.sid);
      expect(details.status, QrStatus.pending);
      expect(details.verifyCode, browserCode);
      expect(details.browserPub, browserKey.publicKey);
      expect(details.clientInfo['reported'], {
        'platform': 'Linux',
        'browser': 'Firefox',
      });
      expect(details.ip, '203.0.113.50');

      // Phone: scan, verify, approve.
      final approved = await scanAndApprove(qr.toString());
      expect(isCanonicalUuid(approved.webSessionId), isTrue);

      // Browser: exactly one poll returns the payload and the web session.
      final result = await browser.pollQrSession(
        sid: session.sid,
        pollToken: session.pollToken,
      );
      expect(result, isA<QrPollApproved>());
      result as QrPollApproved;
      expect(result.session.kind, SessionKind.web);
      expect(result.session.sessionId, approved.webSessionId);
      expect(result.session.idleTimeoutSeconds, 300);
      expect(browser.hasSession, isTrue);

      final vaultKey = await crypto.qrOpenVaultKey(
        browserPrivateKey: browserKey.privateKey,
        phoneEphPub: result.phoneEphPub,
        sid: session.sid,
        nonce: result.nonce,
        ciphertext: result.ciphertext,
      );
      expect(vaultKey, phone.vaultKey);
      browserKey.destroy();

      // Every later poll: consumed, no token, no payload.
      final again = await browser.pollQrSession(
        sid: session.sid,
        pollToken: session.pollToken,
      );
      expect(again, isA<QrPollWaiting>());
      expect(again.status, QrStatus.consumed);

      // The server never saw the vault key.
      final wire = [
        for (final r in server.requests) '${r.url} ${r.headers} ${r.body}',
      ].join('\n');
      expect(wire, isNot(contains(base64UrlEncodeNoPad(phone.vaultKey))));

      // The web session works, and shares data with the phone.
      final itemKeyPhone = await crypto.deriveItemKey(phone.vaultKey);
      final itemKeyBrowser = await crypto.deriveItemKey(vaultKey);
      final id = newUuid();
      final item = LoginItem(
        title: 'Example',
        username: 'aziz',
        password: 'pw',
        createdAt: DateTime.utc(2026, 11, 11),
        updatedAt: DateTime.utc(2026, 11, 11),
      );
      await phone.api.putItem(
        id: id,
        sealed: await crypto.encryptItem(
          itemKey: itemKeyPhone,
          itemId: id,
          version: 1,
          plaintext: item.encode(),
        ),
        expectedVersion: 0,
      );
      final page = await browser.listItems();
      final remote = page.items.single;
      final decrypted = VaultItem.decode(
        await crypto.openItem(
          itemKey: itemKeyBrowser,
          nonce: remote.nonce!,
          itemId: remote.id,
          version: remote.version,
          ciphertext: remote.ciphertext!,
        ),
      );
      expect(decrypted.toJson(), item.toJson());

      // The phone sees the web session and can revoke it remotely.
      final sessions = await phone.api.listSessions();
      expect(sessions.map((s) => s.kind), [
        SessionKind.web,
        SessionKind.mobile,
      ]);
      final web = sessions.first;
      expect(web.id, approved.webSessionId);
      expect(web.deviceId, phone.deviceId);
      expect(web.current, isFalse);
      expect(sessions.last.current, isTrue);
      await phone.api.revokeSession(web.id);

      // Browser: the next request says the session is gone; the client has
      // dropped the token and the app must lock.
      await expectLater(
        browser.heartbeat(),
        throwsA(
          isA<UnauthorizedException>()
              .having((e) => e.code, 'code', 'session_revoked')
              .having((e) => e.sessionEnded, 'sessionEnded', isTrue),
        ),
      );
      expect(browser.hasSession, isFalse);
      expect(browser.heartbeat, throwsStateError);
    });

    test('a web session cannot use mobile-only endpoints', () async {
      final session = await browser.createQrSession(
        browserPub: browserKey.publicKey,
      );
      final qr = QrUri(sid: session.sid, browserPub: browserKey.publicKey);
      await scanAndApprove(qr.toString());
      await browser.pollQrSession(
        sid: session.sid,
        pollToken: session.pollToken,
      );
      final mobileOnly = throwsA(
        isA<ForbiddenException>().having((e) => e.code, 'code', 'mobile_only'),
      );
      await expectLater(browser.listSessions(), mobileOnly);
      await expectLater(browser.auditLog(), mobileOnly);
      await expectLater(browser.qrDetails(session.sid), mobileOnly);
      // A 403 does not end the session.
      expect(browser.hasSession, isTrue);
    });

    test('phone aborts when the server lies about the browser key', () async {
      final session = await browser.createQrSession(
        browserPub: browserKey.publicKey,
      );
      final qr = QrUri(sid: session.sid, browserPub: browserKey.publicKey);
      // A malicious server swaps in its own key, hoping the phone encrypts
      // the vault key to it.
      final attacker = await crypto.generateX25519KeyPair();
      server.qr[qr.sidBase64] = FakeQr(
        session.sid,
        attacker.publicKey,
        session.pollToken,
        const {},
      );
      await expectLater(scanAndApprove(qr.toString()), throwsStateError);
      expect(
        server.requests.where((r) => r.url.path.endsWith('/approve')),
        isEmpty,
      );
    });

    test('an approval for a swapped key is useless to the server', () async {
      // Even if a careless phone skipped the details check, it encrypts to
      // the key in the QR code, and the signature (over the QR key) does not
      // verify against the server's substituted key.
      final session = await browser.createQrSession(
        browserPub: browserKey.publicKey,
      );
      final attacker = await crypto.generateX25519KeyPair();
      server.qr[base64UrlEncodeNoPad(session.sid)] = FakeQr(
        session.sid,
        attacker.publicKey,
        session.pollToken,
        const {},
      );
      final approval = await crypto.approveQrLogin(
        vaultKey: phone.vaultKey,
        deviceSeed: phone.setup.deviceKey.seed,
        sid: session.sid,
        browserPub: browserKey.publicKey,
      );
      await expectLater(
        phone.api.approveQr(sid: session.sid, approval: approval),
        throwsA(
          isA<ForbiddenException>().having(
            (e) => e.code,
            'code',
            'bad_signature',
          ),
        ),
      );
      await expectLater(
        crypto.qrOpenVaultKey(
          browserPrivateKey: attacker.privateKey,
          phoneEphPub: approval.phoneEphPub,
          sid: session.sid,
          nonce: approval.nonce,
          ciphertext: approval.ciphertext,
        ),
        throwsA(isA<DecryptException>()),
      );
    });

    test('an approval signed by another key is refused', () async {
      final session = await browser.createQrSession(
        browserPub: browserKey.publicKey,
      );
      final rogue = await crypto.generateEd25519KeyPair();
      final approval = await crypto.approveQrLogin(
        vaultKey: phone.vaultKey,
        deviceSeed: rogue.seed,
        sid: session.sid,
        browserPub: browserKey.publicKey,
      );
      await expectLater(
        phone.api.approveQr(sid: session.sid, approval: approval),
        throwsA(isA<ForbiddenException>()),
      );
      final poll = await browser.pollQrSession(
        sid: session.sid,
        pollToken: session.pollToken,
      );
      expect(poll.status, QrStatus.pending);
    });

    test('a payload replayed into another session does not decrypt', () async {
      final first = await browser.createQrSession(
        browserPub: browserKey.publicKey,
      );
      final second = await browser.createQrSession(
        browserPub: browserKey.publicKey,
      );
      await scanAndApprove(
        QrUri(sid: first.sid, browserPub: browserKey.publicKey).toString(),
      );
      final result =
          await browser.pollQrSession(
                sid: first.sid,
                pollToken: first.pollToken,
              )
              as QrPollApproved;
      await expectLater(
        crypto.qrOpenVaultKey(
          browserPrivateKey: browserKey.privateKey,
          phoneEphPub: result.phoneEphPub,
          sid: second.sid,
          nonce: result.nonce,
          ciphertext: result.ciphertext,
        ),
        throwsA(isA<DecryptException>()),
      );
    });

    test('reject', () async {
      final session = await browser.createQrSession(
        browserPub: browserKey.publicKey,
      );
      await phone.api.rejectQr(session.sid);
      expect(server.requests.last.method, 'POST');
      expect(server.requests.last.bodyBytes, isEmpty);
      final poll = await browser.pollQrSession(
        sid: session.sid,
        pollToken: session.pollToken,
      );
      expect(poll.status, QrStatus.rejected);
      expect(browser.hasSession, isFalse);
      // Approving afterwards is a conflict.
      final qr = QrUri(sid: session.sid, browserPub: browserKey.publicKey);
      await expectLater(
        scanAndApprove(qr.toString()),
        throwsA(
          isA<ConflictException>().having(
            (e) => e.code,
            'code',
            'qr_not_pending',
          ),
        ),
      );
    });

    test('a wrong poll token and an unknown sid look the same', () async {
      final session = await browser.createQrSession(
        browserPub: browserKey.publicKey,
      );
      final notFound = throwsA(
        isA<NotFoundException>().having((e) => e.code, 'code', 'qr_not_found'),
      );
      await expectLater(
        browser.pollQrSession(
          sid: session.sid,
          pollToken: base64UrlEncodeNoPad(randomBytes(32)),
        ),
        notFound,
      );
      await expectLater(
        browser.pollQrSession(
          sid: randomBytes(sidSize),
          pollToken: session.pollToken,
        ),
        notFound,
      );
    });

    test('expired requests map to GoneException', () async {
      final session = await browser.createQrSession(
        browserPub: browserKey.publicKey,
      );
      server.intercept = (r) => r.url.path.endsWith('/approve')
          ? jsonResponse(410, {
              'error': {'code': 'qr_expired', 'message': 'expired'},
            })
          : null;
      final qr = QrUri(sid: session.sid, browserPub: browserKey.publicKey);
      await expectLater(
        scanAndApprove(qr.toString()),
        throwsA(
          isA<GoneException>()
              .having((e) => e.code, 'code', 'qr_expired')
              .having((e) => e.current, 'current', isNull),
        ),
      );
    });

    test('malformed approval payloads from the server are refused', () async {
      final session = await browser.createQrSession(
        browserPub: browserKey.publicKey,
      );
      Map<String, Object?> approved() => {
        'status': 'approved',
        'session_token': base64UrlEncodeNoPad(randomBytes(32)),
        'session_id': '0b0f4c58-9d5e-4b8a-8a43-0e6c1c7d1f02',
        'kind': 'web',
        'idle_timeout_seconds': 300,
        'phone_eph_pub': base64UrlEncodeNoPad(randomBytes(32)),
        'nonce': base64UrlEncodeNoPad(randomBytes(12)),
        'ciphertext': base64UrlEncodeNoPad(randomBytes(48)),
      };
      final variants = <Map<String, Object?>>[
        {...approved(), 'ciphertext': base64UrlEncodeNoPad(randomBytes(47))},
        {...approved(), 'nonce': base64UrlEncodeNoPad(randomBytes(16))},
        {...approved(), 'phone_eph_pub': 'not base64!'},
        {...approved(), 'phone_eph_pub': '${'A' * 42}B'},
        {...approved(), 'session_token': 'short'},
        {...approved(), 'session_id': 'nope'},
        {...approved(), 'kind': 'admin'},
        {...approved()}..remove('ciphertext'),
        {'status': 'weird'},
        {},
      ];
      for (final body in variants) {
        server.intercept = (_) => jsonResponse(200, body);
        await expectLater(
          browser.pollQrSession(sid: session.sid, pollToken: session.pollToken),
          throwsA(isA<MalformedResponseException>()),
          reason: jsonEncode(body),
        );
        // No token is installed from a response that was rejected.
        expect(browser.hasSession, isFalse);
      }
    });
  });

  group('emergency web login (master password + TOTP)', () {
    late Phone phone;
    late LeopardApiClient web;

    setUp(() async {
      phone = await setUpPhone(server);
      web = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
    });

    Future<String> currentCode() => crypto.totpCode(
      secret: sharedSetup.totpSecret,
      unixSeconds: server.totpTime,
    );

    test('full flow recovers the vault key', () async {
      final params = await web.masterParams();
      expect(params.kdfParams, KdfParams.v1);
      expect(params.salt, sharedSetup.salt);

      final kek = await crypto.deriveKek(
        password: LeopardCrypto.passwordBytes(password),
        salt: params.salt,
        params: params.kdfParams,
      );
      final proof = await crypto.masterAuthKey(kek);
      final result = await web.masterLogin(
        totpCode: await currentCode(),
        proof: proof,
        clientInfo: {'browser': 'Firefox'},
      );
      expect(result.session.kind, SessionKind.web);
      expect(web.hasSession, isTrue);

      final vaultKey = await crypto.unwrapVaultKey(
        kek: kek,
        wrapped: result.wrappedVkMaster,
        label: WrapLabel.master,
      );
      expect(vaultKey, phone.vaultKey);

      // The proof on the wire is the auth key, never the KEK or password.
      final sent =
          jsonDecode(server.requests.last.body) as Map<String, Object?>;
      expect(sent['proof'], base64UrlEncodeNoPad(proof));
      expect(sent['proof'], isNot(base64UrlEncodeNoPad(kek)));
      expect(server.requests.last.body, isNot(contains('horse')));

      // Master-password sessions have no approving device.
      final sessions = await phone.api.listSessions();
      expect(
        sessions.firstWhere((s) => s.kind == SessionKind.web).deviceId,
        isNull,
      );
    });

    test('wrong proof or wrong code give the same error', () async {
      final kek = randomBytes(32);
      final invalid = throwsA(
        isA<UnauthorizedException>()
            .having((e) => e.code, 'code', 'invalid_credentials')
            .having((e) => e.sessionEnded, 'sessionEnded', isFalse),
      );
      await expectLater(
        web.masterLogin(
          totpCode: await currentCode(),
          proof: await crypto.masterAuthKey(kek),
        ),
        invalid,
      );
      final goodKek = await crypto.deriveKek(
        password: LeopardCrypto.passwordBytes(password),
        salt: sharedSetup.salt,
      );
      await expectLater(
        web.masterLogin(
          totpCode: '000000',
          proof: await crypto.masterAuthKey(goodKek),
        ),
        invalid,
      );
      expect(web.hasSession, isFalse);
    });

    test('a failed login does not drop an existing session', () async {
      await expectLater(
        phone.api.masterLogin(totpCode: '000000', proof: randomBytes(32)),
        throwsA(isA<UnauthorizedException>()),
      );
      expect(phone.api.hasSession, isTrue);
    });

    test('a KDF downgrade offered by the server is refused', () async {
      final weak = {...KdfParams.v1.toJson(), 'm_kib': 1024, 't': 1};
      server.intercept = (_) => jsonResponse(200, {
        'kdf_params': weak,
        'salt': base64UrlEncodeNoPad(sharedSetup.salt),
      });
      await expectLater(
        web.masterParams(),
        throwsA(
          isA<MalformedResponseException>().having(
            (e) => e.message,
            'message',
            contains('KDF'),
          ),
        ),
      );
      server.intercept = (_) => jsonResponse(200, {
        'kdf_params': {...KdfParams.v1.toJson(), 'alg': 'pbkdf2'},
        'salt': base64UrlEncodeNoPad(sharedSetup.salt),
      });
      await expectLater(
        web.masterParams(),
        throwsA(isA<MalformedResponseException>()),
      );
      server.intercept = (_) => jsonResponse(200, {
        'kdf_params': KdfParams.v1.toJson(),
        'salt': base64UrlEncodeNoPad(randomBytes(8)),
      });
      await expectLater(
        web.masterParams(),
        throwsA(isA<MalformedResponseException>()),
      );
    });

    test('not initialised', () async {
      final empty = FakeServer(crypto);
      final api = LeopardApiClient(baseUrl: baseUrl, httpClient: empty.client);
      await expectLater(
        api.masterParams(),
        throwsA(
          isA<NotFoundException>().having(
            (e) => e.code,
            'code',
            'not_initialised',
          ),
        ),
      );
    });

    test('rate limiting carries Retry-After', () async {
      server.intercept = (_) => jsonResponse(
        429,
        {
          'error': {'code': 'rate_limited', 'message': 'too many requests'},
        },
        headers: {'retry-after': '37'},
      );
      await expectLater(
        web.masterLogin(totpCode: '123456', proof: randomBytes(32)),
        throwsA(
          isA<RateLimitedException>()
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 37),
              )
              .having((e) => e.code, 'code', 'rate_limited')
              .having((e) => e.statusCode, 'status', 429),
        ),
      );
      // A missing or non-numeric header is tolerated.
      for (final header in <String?>[
        null,
        'Wed, 21 Oct 2026 07:28:00 GMT',
        '-5',
      ]) {
        server.intercept = (_) => jsonResponse(
          429,
          {
            'error': {'code': 'rate_limited', 'message': 'm'},
          },
          headers: {'retry-after': ?header},
        );
        await expectLater(
          web.masterParams(),
          throwsA(
            isA<RateLimitedException>().having(
              (e) => e.retryAfter,
              'retryAfter',
              isNull,
            ),
          ),
        );
      }
    });
  });

  group('recovery', () {
    test('a new phone registers, logs in and unwraps the vault key', () async {
      final oldPhone = await setUpPhone(server);
      final typedKey = formatRecoveryKey(sharedSetup.recoveryKey);

      final api = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
      final recoveryKey = parseRecoveryKey(typedKey);
      final newDevice = await crypto.generateEd25519KeyPair();
      final result = await api.recoveryRegisterDevice(
        proof: await crypto.recoveryAuthKey(recoveryKey),
        deviceLabel: 'New phone',
        devicePublicKey: newDevice.publicKey,
      );
      expect(result.deviceId, isNot(oldPhone.deviceId));
      expect(result.kdfParams, KdfParams.v1);
      expect(result.salt, sharedSetup.salt);
      expect(api.hasSession, isFalse);

      final vaultKey = await crypto.unwrapVaultKey(
        kek: await crypto.recoveryKek(recoveryKey),
        wrapped: result.wrappedVkRecovery,
        label: WrapLabel.recovery,
      );
      expect(vaultKey, sharedSetup.vaultKey);

      // The new device can log in; the old phone is cut off.
      await deviceLogin(api, result.deviceId, newDevice.seed);
      expect((await api.heartbeat()).kind, SessionKind.mobile);
      await expectLater(
        oldPhone.api.heartbeat(),
        throwsA(
          isA<UnauthorizedException>().having(
            (e) => e.sessionEnded,
            'sessionEnded',
            isTrue,
          ),
        ),
      );
      expect(oldPhone.api.hasSession, isFalse);

      // The recovery key itself never went over the wire.
      final wire = server.requests.map((r) => r.body).join('\n');
      expect(wire, isNot(contains(base64UrlEncodeNoPad(recoveryKey))));
      expect(wire, isNot(contains(typedKey)));
    });

    test('a wrong recovery key is refused', () async {
      await setUpPhone(server);
      final api = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
      final device = await crypto.generateEd25519KeyPair();
      await expectLater(
        api.recoveryRegisterDevice(
          proof: await crypto.recoveryAuthKey(crypto.generateRecoveryKey()),
          deviceLabel: 'New phone',
          devicePublicKey: device.publicKey,
        ),
        throwsA(
          isA<UnauthorizedException>().having(
            (e) => e.code,
            'code',
            'invalid_credentials',
          ),
        ),
      );
      expect(server.devices, hasLength(1));
    });
  });

  group('items', () {
    late Phone phone;
    late Uint8List itemKey;

    setUp(() async {
      phone = await setUpPhone(server);
      itemKey = await crypto.deriveItemKey(phone.vaultKey);
    });

    Future<SealedItem> sealNote(String id, int version, String body) =>
        crypto.encryptItem(
          itemKey: itemKey,
          itemId: id,
          version: version,
          plaintext: SecureNoteItem(
            title: 'note',
            body: body,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ).encode(),
        );

    Future<String> readBody(RemoteItem remote) async {
      final item = VaultItem.decode(
        await crypto.openItem(
          itemKey: itemKey,
          nonce: remote.nonce!,
          itemId: remote.id,
          version: remote.version,
          ciphertext: remote.ciphertext!,
        ),
      );
      return (item as SecureNoteItem).body;
    }

    test('create, update, delta sync, delete', () async {
      final id = newUuid();
      final created = await phone.api.putItem(
        id: id,
        sealed: await sealNote(id, 1, 'one'),
        expectedVersion: 0,
      );
      expect(created.version, 1);
      expect(created.deleted, isFalse);
      expect(server.requests.last.method, 'PUT');
      expect(server.requests.last.url.path, '/v1/items/$id');
      expect(jsonDecode(server.requests.last.body), {
        'ciphertext': isA<String>(),
        'nonce': isA<String>(),
        'expected_version': 0,
      });

      final full = await phone.api.listItems();
      expect(server.requests.last.url.hasQuery, isFalse);
      expect(full.items.single.id, id);
      expect(await readBody(full.items.single), 'one');
      // The cursor is kept verbatim, microseconds and all.
      expect(full.serverTime, matches(RegExp(r'\.\d{6}Z$')));

      expect(
        (await phone.api.listItems(since: full.serverTime)).items,
        isEmpty,
      );
      expect(server.requests.last.url.queryParameters, {
        'since': full.serverTime,
      });

      final updated = await phone.api.putItem(
        id: id,
        sealed: await sealNote(id, 2, 'two'),
        expectedVersion: 1,
      );
      expect(updated.version, 2);
      final delta = await phone.api.listItems(since: full.serverTime);
      expect(delta.items.single.version, 2);
      expect(await readBody(delta.items.single), 'two');

      final deleted = await phone.api.deleteItem(id: id, expectedVersion: 2);
      expect(deleted.version, 3);
      expect(deleted.deleted, isTrue);
      expect(server.requests.last.method, 'DELETE');
      expect(jsonDecode(server.requests.last.body), {'expected_version': 2});

      final tombstone = (await phone.api.listItems()).items.single;
      expect(tombstone.deleted, isTrue);
      expect(tombstone.ciphertext, isNull);
      expect(tombstone.nonce, isNull);
      expect(tombstone.deletedAt, isNotNull);
    });

    test(
      'a stale write is a conflict that carries the server version',
      () async {
        final id = newUuid();
        await phone.api.putItem(
          id: id,
          sealed: await sealNote(id, 1, 'one'),
          expectedVersion: 0,
        );
        await phone.api.putItem(
          id: id,
          sealed: await sealNote(id, 2, 'two'),
          expectedVersion: 1,
        );

        // Another client still thinks the item is at version 1.
        ConflictException? conflict;
        try {
          await phone.api.putItem(
            id: id,
            sealed: await sealNote(id, 2, 'mine'),
            expectedVersion: 1,
          );
        } on ConflictException catch (e) {
          conflict = e;
        }
        expect(conflict, isNotNull);
        expect(conflict!.code, 'version_conflict');
        expect(conflict.statusCode, 409);
        expect(conflict.serverVersion, 2);
        expect(conflict.current!.id, id);
        expect(conflict.current!.deleted, isFalse);
        // Nothing was written.
        expect(
          await readBody((await phone.api.listItems()).items.single),
          'two',
        );

        // Creating an id that exists is also a conflict.
        await expectLater(
          phone.api.putItem(
            id: id,
            sealed: await sealNote(id, 1, 'again'),
            expectedVersion: 0,
          ),
          throwsA(
            isA<ConflictException>().having(
              (e) => e.serverVersion,
              'serverVersion',
              2,
            ),
          ),
        );

        // Resolve as documented: re-encrypt for current + 1 and retry.
        final next = conflict.serverVersion! + 1;
        final resolved = await phone.api.putItem(
          id: id,
          sealed: await sealNote(id, next, 'merged'),
          expectedVersion: conflict.serverVersion!,
        );
        expect(resolved.version, 3);
        expect(
          await readBody((await phone.api.listItems()).items.single),
          'merged',
        );
      },
    );

    test('a ciphertext sealed for the wrong version does not open', () async {
      // The client bug this protocol is designed to surface: sealing for the
      // old version instead of expected_version + 1.
      final id = newUuid();
      await phone.api.putItem(
        id: id,
        sealed: await sealNote(id, 1, 'one'),
        expectedVersion: 0,
      );
      await phone.api.putItem(
        id: id,
        sealed: await sealNote(id, 1, 'sealed for v1, stored as v2'),
        expectedVersion: 1,
      );
      final remote = (await phone.api.listItems()).items.single;
      expect(remote.version, 2);
      await expectLater(readBody(remote), throwsA(isA<DecryptException>()));
    });

    test('the server cannot swap ciphertexts between items', () async {
      final a = newUuid();
      final b = newUuid();
      await phone.api.putItem(
        id: a,
        sealed: await sealNote(a, 1, 'A'),
        expectedVersion: 0,
      );
      await phone.api.putItem(
        id: b,
        sealed: await sealNote(b, 1, 'B'),
        expectedVersion: 0,
      );
      final itemA = server.items[a]!;
      final itemB = server.items[b]!;
      server.items[a] = FakeItem(
        a,
        itemA.version,
        itemA.updatedAt,
        itemB.ciphertext,
        itemB.nonce,
      );
      final page = await phone.api.listItems();
      final swapped = page.items.firstWhere((i) => i.id == a);
      await expectLater(readBody(swapped), throwsA(isA<DecryptException>()));
      expect(await readBody(page.items.firstWhere((i) => i.id == b)), 'B');
    });

    test('unknown and deleted items', () async {
      final id = newUuid();
      await expectLater(
        phone.api.putItem(
          id: id,
          sealed: await sealNote(id, 6, 'x'),
          expectedVersion: 5,
        ),
        throwsA(
          isA<NotFoundException>().having(
            (e) => e.code,
            'code',
            'item_not_found',
          ),
        ),
      );
      await phone.api.putItem(
        id: id,
        sealed: await sealNote(id, 1, 'x'),
        expectedVersion: 0,
      );
      await phone.api.deleteItem(id: id, expectedVersion: 1);
      await expectLater(
        phone.api.putItem(
          id: id,
          sealed: await sealNote(id, 3, 'x'),
          expectedVersion: 2,
        ),
        throwsA(
          isA<GoneException>()
              .having((e) => e.code, 'code', 'item_deleted')
              .having((e) => e.current?.version, 'current.version', 2)
              .having((e) => e.current?.deleted, 'current.deleted', isTrue),
        ),
      );
      await expectLater(
        phone.api.deleteItem(id: id, expectedVersion: 2),
        throwsA(isA<GoneException>()),
      );
    });

    test('arguments are validated locally', () async {
      final sealed = await sealNote(newUuid(), 1, 'x');
      final before = server.requests.length;
      expect(
        () => phone.api.putItem(id: 'ABC', sealed: sealed, expectedVersion: 0),
        throwsArgumentError,
      );
      expect(
        () => phone.api.putItem(
          id: newUuid(),
          sealed: sealed,
          expectedVersion: -1,
        ),
        throwsRangeError,
      );
      expect(
        () => phone.api.deleteItem(id: newUuid(), expectedVersion: 0),
        throwsRangeError,
      );
      expect(server.requests, hasLength(before));
    });

    test('malformed item lists are refused', () async {
      final good = {
        'id': newUuid(),
        'version': 1,
        'updated_at': '2026-11-11T10:00:05.123456Z',
        'deleted': false,
        'ciphertext': base64UrlEncodeNoPad(randomBytes(40)),
        'nonce': base64UrlEncodeNoPad(randomBytes(12)),
      };
      final variants = <Object?>[
        {...good, 'nonce': base64UrlEncodeNoPad(randomBytes(11))},
        {...good, 'id': 'UPPER'},
        {...good, 'version': '1'},
        {...good, 'updated_at': 'yesterday'},
        {...good, 'ciphertext': 'a+b/'},
        {...good}..remove('ciphertext'),
        'not an object',
      ];
      for (final item in variants) {
        server.intercept = (_) => jsonResponse(200, {
          'items': [item],
          'server_time': '2026-11-11T10:00:10Z',
        });
        await expectLater(
          phone.api.listItems(),
          throwsA(isA<MalformedResponseException>()),
          reason: jsonEncode(item),
        );
      }
      server.intercept = (_) => jsonResponse(200, {'items': <Object?>[]});
      await expectLater(
        phone.api.listItems(),
        throwsA(isA<MalformedResponseException>()),
      );
    });
  });

  group('sessions and audit', () {
    late Phone phone;

    setUp(() async {
      phone = await setUpPhone(server);
    });

    test('logout drops the token locally even if the request fails', () async {
      await phone.api.logout();
      expect(phone.api.hasSession, isFalse);
      expect(server.requests.last.url.path, '/v1/sessions/logout');

      await deviceLogin(phone.api, phone.deviceId, sharedSetup.deviceKey.seed);
      server.intercept = (_) => throw http.ClientException('offline');
      await expectLater(
        phone.api.logout(),
        throwsA(isA<http.ClientException>()),
      );
      expect(phone.api.hasSession, isFalse);
    });

    test('authenticated calls without a session fail before sending', () {
      final api = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
      final before = server.requests.length;
      expect(api.listItems, throwsStateError);
      expect(api.heartbeat, throwsStateError);
      expect(api.listSessions, throwsStateError);
      expect(server.requests, hasLength(before));
    });

    test('clearSession and useSession', () async {
      final challenge = await phone.api.deviceChallenge(phone.deviceId);
      final grant = await phone.api.deviceVerify(
        deviceId: phone.deviceId,
        nonce: challenge.nonce,
        signature: await crypto.signDeviceAuth(
          deviceSeed: sharedSetup.deviceKey.seed,
          deviceId: phone.deviceId,
          challenge: challenge.nonce,
        ),
      );
      phone.api.clearSession();
      expect(phone.api.hasSession, isFalse);
      phone.api.useSession(grant);
      expect((await phone.api.heartbeat()).sessionId, grant.sessionId);
      expect(grant.toString(), isNot(contains(grant.token)));
    });

    test('revoking an unknown session is not found', () async {
      await expectLater(
        phone.api.revokeSession(newUuid()),
        throwsA(
          isA<NotFoundException>().having(
            (e) => e.code,
            'code',
            'session_not_found',
          ),
        ),
      );
      expect(() => phone.api.revokeSession('x'), throwsArgumentError);
    });

    test('audit log pages newest first', () async {
      // setup + device login already logged two events; add three more.
      for (var i = 0; i < 3; i++) {
        await deviceLogin(
          phone.api,
          phone.deviceId,
          sharedSetup.deviceKey.seed,
        );
      }
      final first = await phone.api.auditLog(limit: 2);
      expect(server.requests.last.url.queryParameters, {'limit': '2'});
      expect(first.entries.map((e) => e.id), [5, 4]);
      expect(first.entries.first.event, 'device_auth_ok');
      expect(first.entries.first.ip, '198.51.100.7');
      expect(first.entries.first.sessionId, isNull);
      expect(first.entries.first.meta, isEmpty);
      expect(first.nextBefore, 4);

      final second = await phone.api.auditLog(
        limit: 2,
        before: first.nextBefore,
      );
      expect(server.requests.last.url.queryParameters, {
        'limit': '2',
        'before': '4',
      });
      expect(second.entries.map((e) => e.id), [3, 2]);

      final last = await phone.api.auditLog(
        limit: 2,
        before: second.nextBefore,
      );
      expect(last.entries.single.event, 'vault_setup');
      expect(last.nextBefore, isNull);

      expect(() => phone.api.auditLog(limit: 0), throwsRangeError);
      expect(() => phone.api.auditLog(limit: 501), throwsRangeError);
      expect(() => phone.api.auditLog(before: 0), throwsRangeError);
    });
  });

  group('error mapping', () {
    late LeopardApiClient api;

    setUp(() {
      api = LeopardApiClient(baseUrl: baseUrl, httpClient: server.client);
    });

    Future<ApiException> errorFor(http.Response response) async {
      server.intercept = (_) => response;
      try {
        await api.masterParams();
      } on ApiException catch (e) {
        return e;
      }
      fail('expected an ApiException');
    }

    Map<String, Object?> err(String code) => {
      'error': {'code': code, 'message': 'message for $code'},
    };

    test('every documented status maps to its type', () async {
      final cases = <(int, String, Matcher)>[
        (400, 'invalid_request', isA<BadRequestException>()),
        (400, 'invalid_json', isA<BadRequestException>()),
        (401, 'unauthenticated', isA<UnauthorizedException>()),
        (403, 'origin_not_allowed', isA<ForbiddenException>()),
        (404, 'not_found', isA<NotFoundException>()),
        (409, 'version_conflict', isA<ConflictException>()),
        (410, 'item_deleted', isA<GoneException>()),
        (413, 'body_too_large', isA<PayloadTooLargeException>()),
        (415, 'unsupported_media_type', isA<UnexpectedStatusException>()),
        (429, 'rate_limited', isA<RateLimitedException>()),
        (500, 'internal', isA<ServerException>()),
        (503, 'internal', isA<ServerException>()),
        (302, 'unknown', isA<UnexpectedStatusException>()),
      ];
      for (final (status, code, matcher) in cases) {
        final e = await errorFor(jsonResponse(status, err(code)));
        expect(e, matcher, reason: '$status $code');
        expect(e.statusCode, status);
        expect(e.code, code);
        expect(e.message, 'message for $code');
        expect(e.toString(), contains(code));
      }
    });

    test('error bodies that are not the documented JSON still map', () async {
      final e = await errorFor(http.Response('<html>Bad Gateway</html>', 502));
      expect(e, isA<ServerException>());
      expect(e.code, 'unknown');
      expect(e.message, 'HTTP 502');
      final e2 = await errorFor(jsonResponse(404, [1, 2, 3]));
      expect(e2, isA<NotFoundException>());
      expect(e2.code, 'unknown');
      final e3 = await errorFor(http.Response.bytes([0xff, 0xfe, 0xfd], 500));
      expect(e3, isA<ServerException>());
    });

    test('a 2xx that is not a JSON object is malformed', () async {
      for (final response in [
        http.Response('ok', 200),
        http.Response('', 200),
        jsonResponse(200, [1]),
        jsonResponse(200, 'x'),
        http.Response.bytes([0xff], 200),
      ]) {
        final e = await errorFor(response);
        expect(e, isA<MalformedResponseException>());
        expect(e.code, 'malformed_response');
      }
    });

    test('session-ending codes drop the token; others keep it', () async {
      final phone = await setUpPhone(server);
      for (final code in [
        'session_revoked',
        'session_expired',
        'invalid_token',
        'unauthenticated',
      ]) {
        await deviceLogin(
          phone.api,
          phone.deviceId,
          sharedSetup.deviceKey.seed,
        );
        expect(phone.api.hasSession, isTrue);
        server.intercept = (_) => jsonResponse(401, err(code));
        await expectLater(
          phone.api.listItems(),
          throwsA(
            isA<UnauthorizedException>().having(
              (e) => e.sessionEnded,
              'sessionEnded',
              isTrue,
            ),
          ),
          reason: code,
        );
        expect(phone.api.hasSession, isFalse, reason: code);
        server.intercept = null;
      }

      await deviceLogin(phone.api, phone.deviceId, sharedSetup.deviceKey.seed);
      for (final status in [400, 403, 404, 409, 429, 500]) {
        server.intercept = (_) => jsonResponse(status, err('x'));
        await expectLater(phone.api.listItems(), throwsA(isA<ApiException>()));
        expect(phone.api.hasSession, isTrue, reason: '$status');
      }
    });

    test('transport errors and timeouts propagate unchanged', () async {
      server.intercept = (_) => throw http.ClientException('connection reset');
      await expectLater(api.health(), throwsA(isA<http.ClientException>()));

      final slow = LeopardApiClient(
        baseUrl: baseUrl,
        timeout: const Duration(milliseconds: 50),
        httpClient: MockClient((request) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return jsonResponse(200, {'status': 'ok'});
        }),
      );
      await expectLater(slow.health(), throwsA(isA<TimeoutException>()));
    });

    test('exceptions and models do not print secrets', () async {
      final e = await errorFor(jsonResponse(401, err('invalid_credentials')));
      expect(
        e.toString(),
        'UnauthorizedException(401 invalid_credentials): '
        'message for invalid_credentials',
      );
      final session = QrSession(
        sid: randomBytes(16),
        pollToken: 'super-secret-poll-token',
        expiresAt: DateTime.utc(2026),
        verifyCode: '123456',
        qrUri: 'leopard://qr',
      );
      expect(session.toString(), isNot(contains('super-secret')));
    });
  });

  test('close forgets the session', () async {
    final phone = await setUpPhone(server);
    phone.api.close();
    expect(phone.api.hasSession, isFalse);
  });
}
