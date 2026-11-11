// HttpLeopardApi over a scripted HTTP client: what goes on the wire for a
// web session, and what happens on a 401.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/core/error/failures.dart';
import 'package:leopard_web/core/network/leopard_api.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

http.Response json(int status, Object body, {Map<String, String>? headers}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json', ...?headers},
    );

http.Response error(int status, String code) => json(status, {
  'error': {'code': code, 'message': 'test'},
});

void main() {
  final sid = bytesOf(sidSize, 5);
  final pollToken = tokenOf(0x61);
  final sessionToken = tokenOf(0x21);
  late List<http.Request> requests;
  late http.Response Function(http.Request request) respond;
  late HttpLeopardApi api;

  Map<String, Object?> approvedBody() => {
    'status': 'approved',
    'session_token': sessionToken,
    'session_id': sessionIdA,
    'kind': 'web',
    'idle_timeout_seconds': 300,
    'phone_eph_pub': base64UrlEncodeNoPad(bytesOf(x25519KeySize, 1)),
    'nonce': base64UrlEncodeNoPad(bytesOf(nonceSize, 2)),
    'ciphertext': base64UrlEncodeNoPad(bytesOf(qrCiphertextSize, 3)),
  };

  setUp(() {
    requests = [];
    respond = (_) => error(500, 'internal');
    api = HttpLeopardApi(
      baseUrl: Uri.parse('https://api.example.com'),
      httpClient: MockClient((request) async {
        requests.add(request);
        return respond(request);
      }),
    );
  });

  tearDown(() => api.dispose());

  /// Collects the web session the way the QR login does.
  Future<void> signIn() async {
    respond = (_) => json(200, approvedBody());
    await api.pollQrSession(sid: sid, pollToken: pollToken);
    requests.clear();
  }

  test('polling sends the poll token header and installs the session', () async {
    expect(api.hasSession, isFalse);
    respond = (_) => json(200, approvedBody());

    final result = await api.pollQrSession(sid: sid, pollToken: pollToken);

    expect(result, isA<QrPollApproved>());
    final request = requests.single;
    expect(request.method, 'GET');
    expect(request.url.path, '/v1/qr/${base64UrlEncodeNoPad(sid)}');
    expect(request.headers['X-Leopard-Poll-Token'], pollToken);
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(api.hasSession, isTrue);
  });

  test('item calls carry the bearer token', () async {
    await signIn();
    respond = (_) => json(200, {
      'items': <Object?>[],
      'server_time': '2026-11-11T10:00:10Z',
    });

    await api.listItems(since: '2026-11-11T10:00:00Z');

    final request = requests.single;
    expect(request.headers['Authorization'], 'Bearer $sessionToken');
    expect(request.url.queryParameters, {'since': '2026-11-11T10:00:00Z'});
  });

  test('without a session nothing is sent', () async {
    await expectLater(api.listItems(), throwsA(isA<VaultLockedFailure>()));
    await expectLater(api.heartbeat(), throwsA(isA<VaultLockedFailure>()));
    await api.logout();
    expect(requests, isEmpty);
  });

  for (final code in [
    'session_revoked',
    'session_expired',
    'invalid_token',
    'unauthenticated',
  ]) {
    test('401 $code: the token is dropped and the end is announced', () async {
      await signIn();
      final ended = <UnauthorizedException>[];
      final subscription = api.sessionEnded.listen(ended.add);
      respond = (_) => error(401, code);

      await expectLater(
        api.heartbeat(),
        throwsA(isA<UnauthorizedException>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(ended.single.code, code);
      expect(api.hasSession, isFalse);
      await subscription.cancel();
    });
  }

  test('a 401 for wrong login credentials is not a session end', () async {
    final ended = <UnauthorizedException>[];
    final subscription = api.sessionEnded.listen(ended.add);
    respond = (_) => error(401, 'invalid_credentials');

    await expectLater(
      api.masterLogin(totpCode: '492039', proof: bytesOf(keySize, 9)),
      throwsA(isA<UnauthorizedException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(ended, isEmpty);
    final body = jsonDecode(requests.single.body) as Map<String, Object?>;
    expect(body.keys, containsAll(['totp_code', 'proof']));
    await subscription.cancel();
  });

  test('other errors do not end the session', () async {
    await signIn();
    final ended = <UnauthorizedException>[];
    final subscription = api.sessionEnded.listen(ended.add);
    respond = (_) => json(
      429,
      {
        'error': {'code': 'rate_limited', 'message': 'test'},
      },
      headers: {'retry-after': '12'},
    );

    await expectLater(
      api.listItems(),
      throwsA(
        isA<RateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 12),
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(ended, isEmpty);
    expect(api.hasSession, isTrue);
    await subscription.cancel();
  });

  test('logout calls the server and drops the token either way', () async {
    await signIn();
    respond = (_) => json(200, {'status': 'logged_out'});
    await api.logout();
    expect(requests.single.url.path, '/v1/sessions/logout');
    expect(requests.single.headers['Authorization'], 'Bearer $sessionToken');
    expect(api.hasSession, isFalse);

    await signIn();
    respond = (_) => error(500, 'internal');
    await expectLater(api.logout(), throwsA(isA<ServerException>()));
    expect(api.hasSession, isFalse);
  });

  test('a login waits for a logout that is still in flight', () async {
    await signIn();
    final order = <String>[];
    respond = (request) {
      order.add(request.url.path);
      return request.url.path.endsWith('/logout')
          ? json(200, {'status': 'logged_out'})
          : json(200, approvedBody());
    };

    final logout = api.logout();
    final login = api.pollQrSession(sid: sid, pollToken: pollToken);
    await Future.wait([logout, login]);

    expect(order.first, '/v1/sessions/logout');
    expect(api.hasSession, isTrue, reason: 'the new token survives');
  });

  test('plain http is refused unless explicitly allowed', () {
    expect(
      () => HttpLeopardApi(baseUrl: Uri.parse('http://api.example.com')),
      throwsArgumentError,
    );
    final local = HttpLeopardApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      allowInsecureHttp: true,
    );
    expect(local.hasSession, isFalse);
  });
}
