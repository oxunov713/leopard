import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leopard_core/leopard_core.dart';

/// An in-memory stand-in for the Go server, good enough to exercise the
/// client end to end. It follows `docs/api.md` and, like the real server,
/// does the server half of the cryptography for real: it verifies Ed25519
/// signatures over messages it rebuilds from **its own** state, compares
/// SHA-256 of proofs with stored verifiers, and checks TOTP codes.
///
/// It never sees a vault key, a KEK or a private key; tests assert that.
class FakeServer {
  FakeServer(this.crypto);

  final LeopardCrypto crypto;

  /// Every request received, for assertions about what went on the wire.
  final List<http.Request> requests = [];

  /// When set, replaces the response of the next request.
  http.Response? Function(http.Request request)? intercept;

  Map<String, Object?>? vault;
  final Map<String, Uint8List> devices = {};
  final Map<String, String> challenges = {};
  final Map<String, FakeSession> sessions = {};
  final Map<String, FakeQr> qr = {};
  final Map<String, FakeItem> items = {};
  final List<Map<String, Object?>> audit = [];
  String? requiredSetupToken;
  int _uuidCounter = 0;
  int _clock = 0;
  int totpTime = 1111111109;

  http.Client get client => MockClient(handle);

  String _uuid() =>
      '00000000-0000-4000-8000-${(++_uuidCounter).toString().padLeft(12, '0')}';

  /// A strictly increasing RFC 3339 timestamp with microseconds.
  String _now() {
    _clock++;
    return '2026-11-11T10:00:${(_clock ~/ 1000 % 60).toString().padLeft(2, '0')}'
        '.${(_clock % 1000).toString().padLeft(3, '0')}456Z';
  }

  String _token() => base64UrlEncodeNoPad(randomBytes(tokenSize));

  void _log(String event) =>
      audit.add({'id': audit.length + 1, 'ts': _now(), 'event': event});

  static http.Response _json(int status, Object? body, {String? retryAfter}) =>
      http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'x-request-id': 'req-test',
          'retry-after': ?retryAfter,
        },
      );

  static http.Response _error(int status, String code, [Object? current]) =>
      _json(status, {
        'error': {'code': code, 'message': 'fake: $code'},
        'current': ?current,
      });

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final hook = intercept;
    if (hook != null) {
      final replaced = hook(request);
      if (replaced != null) return replaced;
    }
    try {
      return await _route(request);
    } on _Reply catch (reply) {
      return reply.response;
    }
  }

  Map<String, Object?> _body(http.Request request) {
    if (request.headers['content-type'] != 'application/json') {
      throw _Reply(_error(415, 'unsupported_media_type'));
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(request.body);
    } on FormatException {
      throw _Reply(_error(400, 'invalid_json'));
    }
    if (decoded is! Map<String, Object?>) {
      throw _Reply(_error(400, 'invalid_json'));
    }
    return decoded;
  }

  Uint8List _bin(Map<String, Object?> body, String key, int? size) {
    final value = body[key];
    if (value is String) {
      try {
        final bytes = base64UrlDecodeNoPad(value);
        if (size == null || bytes.length == size) return bytes;
      } on InvalidFormatException {
        // Reported below.
      }
    }
    throw _Reply(_error(400, 'invalid_request'));
  }

  void _onlyKeys(Map<String, Object?> body, Set<String> allowed) {
    if (!body.keys.every(allowed.contains)) {
      throw _Reply(_error(400, 'invalid_json'));
    }
  }

  FakeSession _auth(http.Request request, {bool mobileOnly = false}) {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) {
      throw _Reply(_error(401, 'unauthenticated'));
    }
    final session = sessions[header.substring(7)];
    if (session == null) throw _Reply(_error(401, 'invalid_token'));
    if (session.revoked) throw _Reply(_error(401, 'session_revoked'));
    if (mobileOnly && session.kind != 'mobile') {
      throw _Reply(_error(403, 'mobile_only'));
    }
    return session;
  }

  Map<String, Object?> _grant(String token, FakeSession s) => {
    'session_token': token,
    'session_id': s.id,
    'kind': s.kind,
    'idle_timeout_seconds': s.kind == 'web' ? 300 : 86400,
  };

  Future<http.Response> _route(http.Request request) async {
    final path = request.url.pathSegments;
    final method = request.method;
    final route = '$method /${path.join('/')}';

    if (route == 'GET /healthz') return _json(200, {'status': 'ok'});

    if (route == 'POST /v1/setup') return _setup(request);
    if (route == 'POST /v1/auth/device/challenge') {
      final body = _body(request);
      final nonce = base64UrlEncodeNoPad(randomBytes(deviceChallengeSize));
      challenges[nonce] = body['device_id']! as String;
      return _json(200, {'nonce': nonce, 'expires_at': _now()});
    }
    if (route == 'POST /v1/auth/device/verify') return _deviceVerify(request);

    if (route == 'POST /v1/qr') return _qrCreate(request);
    if (path.length >= 3 && path[0] == 'v1' && path[1] == 'qr') {
      final entry = qr[path[2]];
      if (path.length == 3 && method == 'GET') return _qrPoll(request, entry);
      final session = _auth(request, mobileOnly: true);
      if (entry == null) return _error(404, 'qr_not_found');
      if (path.length == 4 && path[3] == 'details' && method == 'GET') {
        return _json(200, {
          'sid': path[2],
          'status': entry.status,
          'browser_pub': base64UrlEncodeNoPad(entry.browserPub),
          'client_info': {'user_agent': 'test', 'reported': entry.clientInfo},
          'ip': '203.0.113.50',
          'created_at': _now(),
          'expires_at': _now(),
          'verify_code': await crypto.verifyCode(
            sid: entry.sid,
            browserPub: entry.browserPub,
          ),
        });
      }
      if (path.length == 4 && path[3] == 'approve' && method == 'POST') {
        return _qrApprove(request, entry, session);
      }
      if (path.length == 4 && path[3] == 'reject' && method == 'POST') {
        if (entry.status != 'pending') return _error(409, 'qr_not_pending');
        entry.status = 'rejected';
        return _json(200, {'status': 'rejected'});
      }
    }

    if (route == 'GET /v1/auth/master/params') {
      final v = vault;
      if (v == null) return _error(404, 'not_initialised');
      return _json(200, {'kdf_params': v['kdf_params'], 'salt': v['salt']});
    }
    if (route == 'POST /v1/auth/master/login') return _masterLogin(request);
    if (route == 'POST /v1/recovery/register-device') return _recover(request);

    if (route == 'GET /v1/items') {
      _auth(request);
      final since = request.url.queryParameters['since'];
      final list = items.values.toList()
        ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      return _json(200, {
        'items': [
          for (final item in list)
            if (since == null || item.updatedAt.compareTo(since) > 0)
              item.toJson(),
        ],
        'server_time': _now(),
      });
    }
    if (path.length == 3 && path[0] == 'v1' && path[1] == 'items') {
      _auth(request);
      if (method == 'PUT') return _itemPut(request, path[2]);
      if (method == 'DELETE') return _itemDelete(request, path[2]);
    }

    if (route == 'POST /v1/sessions/heartbeat') {
      final s = _auth(request);
      return _json(200, {
        'session_id': s.id,
        'kind': s.kind,
        'idle_timeout_seconds': s.kind == 'web' ? 300 : 86400,
        'expires_at': _now(),
        'server_time': _now(),
      });
    }
    if (route == 'POST /v1/sessions/logout') {
      _auth(request).revoked = true;
      return _json(200, {'status': 'logged_out'});
    }
    if (route == 'GET /v1/sessions') {
      final me = _auth(request, mobileOnly: true);
      return _json(200, {
        'sessions': [
          for (final s in sessions.values.toList().reversed)
            if (!s.revoked && s.live)
              {
                'id': s.id,
                'kind': s.kind,
                'device_id': s.deviceId,
                'client_info': s.kind == 'web' ? {'user_agent': 'test'} : null,
                'ip': '203.0.113.50',
                'created_at': _now(),
                'last_seen': _now(),
                'idle_timeout_seconds': s.kind == 'web' ? 300 : 86400,
                'expires_at': _now(),
                'current': identical(s, me),
              },
        ],
        'server_time': _now(),
      });
    }
    if (path.length == 3 &&
        path[0] == 'v1' &&
        path[1] == 'sessions' &&
        method == 'DELETE') {
      _auth(request, mobileOnly: true);
      for (final s in sessions.values) {
        if (s.id == path[2] && !s.revoked) {
          s.revoked = true;
          return _json(200, {'status': 'revoked', 'id': s.id});
        }
      }
      return _error(404, 'session_not_found');
    }

    if (route == 'GET /v1/audit') {
      _auth(request, mobileOnly: true);
      final limit = int.parse(request.url.queryParameters['limit'] ?? '100');
      final before = int.tryParse(request.url.queryParameters['before'] ?? '');
      final page = audit.reversed
          .where((e) => before == null || (e['id']! as int) < before)
          .take(limit)
          .toList();
      return _json(200, {
        'entries': [
          for (final e in page)
            {
              ...e,
              'session_id': null,
              'device_id': null,
              'ip': '198.51.100.7',
              'meta': <String, Object?>{},
            },
        ],
        'next_before': page.length == limit ? page.last['id'] : null,
      });
    }

    return _error(404, 'not_found');
  }

  http.Response _setup(http.Request request) {
    final body = _body(request);
    final required = requiredSetupToken;
    if (required != null &&
        request.headers['x-leopard-setup-token'] != required) {
      return _error(403, 'setup_token_required');
    }
    if (vault != null) return _error(409, 'already_initialised');
    _onlyKeys(body, {
      'kdf_params',
      'salt',
      'wrapped_vk_master',
      'wrapped_vk_recovery',
      'master_auth_verifier',
      'recovery_auth_verifier',
      'totp_secret',
      'device',
    });
    _bin(body, 'salt', saltSize);
    _bin(body, 'wrapped_vk_master', wrappedVkSize);
    _bin(body, 'wrapped_vk_recovery', wrappedVkSize);
    _bin(body, 'master_auth_verifier', 32);
    _bin(body, 'recovery_auth_verifier', 32);
    _bin(body, 'totp_secret', null);
    final device = body['device']! as Map<String, Object?>;
    final id = _uuid();
    devices[id] = _bin(device, 'ed25519_pub', ed25519PublicKeySize);
    vault = body;
    _log('vault_setup');
    return _json(201, {'device_id': id, 'created_at': _now()});
  }

  Future<http.Response> _deviceVerify(http.Request request) async {
    final body = _body(request);
    final deviceId = body['device_id']! as String;
    final nonce = _bin(body, 'nonce', deviceChallengeSize);
    final signature = _bin(body, 'signature', ed25519SignatureSize);
    // Single use: consumed by the attempt, successful or not.
    final issuedTo = challenges.remove(body['nonce']);
    final publicKey = devices[deviceId];
    final ok =
        issuedTo == deviceId &&
        publicKey != null &&
        await crypto.ed25519Verify(
          publicKey: publicKey,
          message: LeopardCrypto.deviceAuthMessage(
            deviceId: deviceId,
            challenge: nonce,
          ),
          signature: signature,
        );
    if (!ok) {
      _log('device_auth_failed');
      return _error(401, 'device_auth_failed');
    }
    final token = _token();
    final session = FakeSession(_uuid(), 'mobile', deviceId);
    sessions[token] = session;
    _log('device_auth_ok');
    return _json(200, _grant(token, session));
  }

  Future<http.Response> _qrCreate(http.Request request) async {
    final body = _body(request);
    _onlyKeys(body, {'browser_pub', 'client_info'});
    final browserPub = _bin(body, 'browser_pub', x25519KeySize);
    final sid = randomBytes(sidSize);
    final entry = FakeQr(
      sid,
      browserPub,
      _token(),
      (body['client_info'] as Map<String, Object?>?) ?? const {},
    );
    qr[base64UrlEncodeNoPad(sid)] = entry;
    _log('qr_created');
    return _json(201, {
      'sid': base64UrlEncodeNoPad(sid),
      'poll_token': entry.pollToken,
      'expires_at': _now(),
      'verify_code': await crypto.verifyCode(sid: sid, browserPub: browserPub),
      'qr_uri': QrUri(sid: sid, browserPub: browserPub).toString(),
    });
  }

  http.Response _qrPoll(http.Request request, FakeQr? entry) {
    if (entry == null ||
        request.headers['x-leopard-poll-token'] != entry.pollToken) {
      return _error(404, 'qr_not_found');
    }
    if (entry.status != 'approved') {
      return _json(200, {'status': entry.status, 'expires_at': _now()});
    }
    // Exactly once: mint the token now, erase the payload.
    final token = _token();
    final session = entry.pendingSession!..live = true;
    sessions[token] = session;
    final payload = entry.payload!;
    entry
      ..status = 'consumed'
      ..payload = null;
    _log('qr_consumed');
    return _json(200, {
      'status': 'approved',
      ..._grant(token, session),
      ...payload,
    });
  }

  Future<http.Response> _qrApprove(
    http.Request request,
    FakeQr entry,
    FakeSession session,
  ) async {
    final body = _body(request);
    _onlyKeys(body, {'phone_eph_pub', 'nonce', 'ciphertext', 'signature'});
    final phoneEphPub = _bin(body, 'phone_eph_pub', x25519KeySize);
    final nonce = _bin(body, 'nonce', nonceSize);
    final ciphertext = _bin(body, 'ciphertext', qrCiphertextSize);
    final signature = _bin(body, 'signature', ed25519SignatureSize);
    if (entry.status != 'pending') return _error(409, 'qr_not_pending');
    // Rebuilt from the server's OWN sid and browser_pub.
    final message = LeopardCrypto.qrApproveMessage(
      sid: entry.sid,
      browserPub: entry.browserPub,
      phoneEphPub: phoneEphPub,
      nonce: nonce,
      ciphertext: ciphertext,
    );
    final ok = await crypto.ed25519Verify(
      publicKey: devices[session.deviceId]!,
      message: message,
      signature: signature,
    );
    if (!ok) {
      _log('qr_approve_failed');
      return _error(403, 'bad_signature');
    }
    final pending = FakeSession(_uuid(), 'web', session.deviceId)..live = false;
    entry
      ..status = 'approved'
      ..pendingSession = pending
      ..payload = {
        'phone_eph_pub': body['phone_eph_pub'],
        'nonce': body['nonce'],
        'ciphertext': body['ciphertext'],
      };
    _log('qr_approved');
    return _json(200, {'status': 'approved', 'session_id': pending.id});
  }

  Future<http.Response> _masterLogin(http.Request request) async {
    final body = _body(request);
    _onlyKeys(body, {'totp_code', 'proof', 'client_info'});
    final v = vault;
    if (v == null) return _error(401, 'invalid_credentials');
    final proof = _bin(body, 'proof', keySize);
    final verifier = base64UrlDecodeNoPad(v['master_auth_verifier']! as String);
    final expectedCode = await crypto.totpCode(
      secret: base64UrlDecodeNoPad(v['totp_secret']! as String),
      unixSeconds: totpTime,
    );
    final proofOk = constantTimeEquals(await crypto.sha256(proof), verifier);
    if (!proofOk || body['totp_code'] != expectedCode) {
      _log('master_login_failed');
      return _error(401, 'invalid_credentials');
    }
    final token = _token();
    final session = FakeSession(_uuid(), 'web', null);
    sessions[token] = session;
    _log('master_login_ok');
    return _json(200, {
      ..._grant(token, session),
      'wrapped_vk_master': v['wrapped_vk_master'],
    });
  }

  Future<http.Response> _recover(http.Request request) async {
    final body = _body(request);
    _onlyKeys(body, {'proof', 'device'});
    final v = vault;
    if (v == null) return _error(401, 'invalid_credentials');
    final proof = _bin(body, 'proof', keySize);
    final verifier = base64UrlDecodeNoPad(
      v['recovery_auth_verifier']! as String,
    );
    if (!constantTimeEquals(await crypto.sha256(proof), verifier)) {
      _log('recovery_failed');
      return _error(401, 'invalid_credentials');
    }
    final device = body['device']! as Map<String, Object?>;
    // Every existing device and session is revoked.
    devices.clear();
    for (final s in sessions.values) {
      s.revoked = true;
    }
    final id = _uuid();
    devices[id] = _bin(device, 'ed25519_pub', ed25519PublicKeySize);
    _log('recovery_device_registered');
    return _json(201, {
      'device_id': id,
      'wrapped_vk_recovery': v['wrapped_vk_recovery'],
      'kdf_params': v['kdf_params'],
      'salt': v['salt'],
    });
  }

  http.Response _itemPut(http.Request request, String id) {
    if (!isCanonicalUuid(id)) return _error(400, 'invalid_request');
    final body = _body(request);
    _onlyKeys(body, {'ciphertext', 'nonce', 'expected_version'});
    final expected = body['expected_version'];
    if (expected is! int || expected < 0) {
      return _error(400, 'invalid_request');
    }
    _bin(body, 'nonce', nonceSize);
    if (_bin(body, 'ciphertext', null).length <= tagSize) {
      return _error(400, 'invalid_request');
    }
    final current = items[id];
    if (current == null) {
      if (expected != 0) return _error(404, 'item_not_found');
    } else if (current.deleted) {
      return _error(410, 'item_deleted', current.meta());
    } else if (current.version != expected) {
      return _error(409, 'version_conflict', current.meta());
    }
    final item = FakeItem(
      id,
      expected + 1,
      _now(),
      body['ciphertext']! as String,
      body['nonce']! as String,
    );
    items[id] = item;
    return _json(expected == 0 ? 201 : 200, item.meta());
  }

  http.Response _itemDelete(http.Request request, String id) {
    final body = _body(request);
    final expected = body['expected_version'];
    if (expected is! int || expected < 1) {
      return _error(400, 'invalid_request');
    }
    final current = items[id];
    if (current == null) return _error(404, 'item_not_found');
    if (current.deleted) return _error(410, 'item_deleted', current.meta());
    if (current.version != expected) {
      return _error(409, 'version_conflict', current.meta());
    }
    final tombstone = FakeItem(id, expected + 1, _now(), null, null);
    items[id] = tombstone;
    _log('item_deleted');
    return _json(200, tombstone.meta());
  }
}

class _Reply implements Exception {
  _Reply(this.response);

  final http.Response response;
}

class FakeSession {
  FakeSession(this.id, this.kind, this.deviceId);

  final String id;
  final String kind;
  final String? deviceId;
  bool revoked = false;
  bool live = true;
}

class FakeQr {
  FakeQr(this.sid, this.browserPub, this.pollToken, this.clientInfo);

  final Uint8List sid;
  final Uint8List browserPub;
  final String pollToken;
  final Map<String, Object?> clientInfo;
  String status = 'pending';
  FakeSession? pendingSession;
  Map<String, Object?>? payload;
}

class FakeItem {
  FakeItem(this.id, this.version, this.updatedAt, this.ciphertext, this.nonce);

  final String id;
  final int version;
  final String updatedAt;
  final String? ciphertext;
  final String? nonce;

  bool get deleted => ciphertext == null;

  Map<String, Object?> meta() => {
    'id': id,
    'version': version,
    'updated_at': updatedAt,
    'deleted': deleted,
  };

  Map<String, Object?> toJson() => {
    ...meta(),
    if (deleted) 'deleted_at': updatedAt,
    'ciphertext': ?ciphertext,
    'nonce': ?nonce,
  };
}
