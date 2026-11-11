// ApiRemoteVault: device login (crypto-spec §9) and re-login on 401,
// against an HTTP stub that verifies the signature like the server does.
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/core/error/failures.dart';
import 'package:leopard_mobile/core/network/remote_vault.dart';
import 'package:leopard_mobile/core/security/key_derivation.dart';
import 'package:leopard_mobile/core/session/vault_session.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

http.Response json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response error(int status, String code) => json(status, {
  'error': {'code': code, 'message': code},
});

void main() {
  final crypto = newLeopardCrypto();
  final deviceSeed = bytesOf(ed25519SeedSize, 0x51);
  late Uint8List devicePublicKey;
  late VaultSession session;
  late ApiRemoteVault remote;
  late List<String> log;

  // Server state.
  late int tokenCounter;
  late Set<String> liveTokens;
  late bool deviceRevoked;
  final challenge = bytesOf(deviceChallengeSize, 0x33);

  String newToken() {
    final token = base64UrlEncodeNoPad(bytesOf(tokenSize, ++tokenCounter));
    liveTokens.add(token);
    return token;
  }

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    log.add('${request.method} $path');
    if (path == '/v1/auth/device/challenge') {
      return json(200, {
        'nonce': base64UrlEncodeNoPad(challenge),
        'expires_at': '2026-11-11T10:01:00Z',
      });
    }
    if (path == '/v1/auth/device/verify') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final ok =
          !deviceRevoked &&
          body['device_id'] == deviceIdA &&
          await crypto.ed25519Verify(
            publicKey: devicePublicKey,
            message: LeopardCrypto.deviceAuthMessage(
              deviceId: deviceIdA,
              challenge: challenge,
            ),
            signature: base64UrlDecodeNoPad(body['signature']! as String),
          );
      if (!ok) return error(401, 'device_auth_failed');
      return json(200, {
        'session_token': newToken(),
        'session_id': itemIdA,
        'kind': 'mobile',
        'idle_timeout_seconds': 86400,
      });
    }
    final auth = request.headers['Authorization'] ?? '';
    if (!auth.startsWith('Bearer ') ||
        !liveTokens.contains(auth.substring(7))) {
      return error(401, 'session_expired');
    }
    if (path == '/v1/items') {
      return json(200, {
        'items': <Object>[],
        'server_time': '2026-11-11T10:00:10Z',
      });
    }
    if (path == '/v1/sessions') {
      return json(200, {
        'sessions': <Object>[],
        'server_time': '2026-11-11T10:00:10Z',
      });
    }
    return error(404, 'not_found');
  }

  setUp(() async {
    devicePublicKey = (await crypto.ed25519KeyPairFromSeed(
      deviceSeed,
    )).publicKey;
    session = await unlockedSession(crypto, deviceSeed: deviceSeed);
    log = [];
    tokenCounter = 0;
    liveTokens = {};
    deviceRevoked = false;
    remote = ApiRemoteVault(
      session: session,
      crypto: crypto,
      clientFactory: (url) =>
          LeopardApiClient(baseUrl: url, httpClient: MockClient(handle)),
    )..configure(serverUrl);
  });

  test('logs in with the device key before the first request', () async {
    final page = await remote.listItems();
    expect(page.serverTime, '2026-11-11T10:00:10Z');
    expect(log, [
      'POST /v1/auth/device/challenge',
      'POST /v1/auth/device/verify',
      'GET /v1/items',
    ]);
  });

  test('reuses the session for later requests', () async {
    await remote.listItems();
    await remote.listSessions();
    expect(log.where((l) => l.contains('/auth/')), hasLength(2));
  });

  test('an expired session is renewed once, transparently', () async {
    await remote.listItems();
    liveTokens.clear(); // the server forgot the session
    log.clear();

    await remote.listItems();

    expect(log, [
      'GET /v1/items',
      'POST /v1/auth/device/challenge',
      'POST /v1/auth/device/verify',
      'GET /v1/items',
    ]);
  });

  test('forgetSession (lock) forces a new login next time', () async {
    await remote.listItems();
    remote.forgetSession();
    log.clear();
    await remote.listItems();
    expect(log.first, 'POST /v1/auth/device/challenge');
  });

  test('a revoked device gets DeviceRevokedFailure', () async {
    deviceRevoked = true;
    await expectLater(remote.listItems(), throwsA(isA<DeviceRevokedFailure>()));
    expect(log, isNot(contains('GET /v1/items')));
  });

  test('a signature from another key is refused by the server', () async {
    session.open(
      UnlockedVault(
        deviceId: deviceIdA,
        vaultKey: bytesOf(keySize, 1),
        itemKey: bytesOf(keySize, 2),
        deviceSeed: bytesOf(ed25519SeedSize, 0x99),
      ),
    );
    await expectLater(remote.listItems(), throwsA(isA<DeviceRevokedFailure>()));
  });

  test('nothing is sent while the vault is locked', () async {
    session.close();
    await expectLater(remote.listItems(), throwsA(isA<VaultLockedFailure>()));
    expect(log, isEmpty);
  });

  test('concurrent requests share one login', () async {
    await Future.wait([remote.listItems(), remote.listSessions()]);
    expect(log.where((l) => l.endsWith('/challenge')), hasLength(1));
  });
}
