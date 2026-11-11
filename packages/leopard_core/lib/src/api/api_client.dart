import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../crypto/constants.dart';
import '../crypto/encoding.dart';
import '../crypto/errors.dart';
import '../crypto/kdf_params.dart';
import '../crypto/key_types.dart';
import 'api_exceptions.dart';
import 'api_models.dart';

/// A typed client for the Leopard HTTP API (`docs/api.md`).
///
/// * Binary fields are `Uint8List` in this API and strict base64url on the
///   wire. Sizes of everything received are checked; a response that does
///   not match the documented shape is a [MalformedResponseException].
/// * Error responses become [ApiException] subclasses. Transport errors
///   (`http.ClientException`, [TimeoutException]) propagate unchanged.
/// * **Tokens are held in memory only.** The session token lives in this
///   object and nowhere else; it is never written to storage or logged, and
///   it is dropped on [logout], on [clearSession] and when the server
///   answers an authenticated request with 401. The phone does not persist
///   it either: it re-authenticates with its device key.
/// * This class does no cryptography. Callers combine it with
///   `LeopardCrypto`; the checks the protocol requires of the client (for
///   example comparing `browser_pub` from the QR code with [qrDetails]) are
///   called out on each method.
final class LeopardApiClient {
  /// Creates a client for the server at [baseUrl], for example
  /// `https://vault.example.com`.
  ///
  /// [baseUrl] must be `https`. Plain `http` is refused unless
  /// [allowInsecureHttp] is set, which is meant for local development only:
  /// proofs and tokens are bearer secrets.
  ///
  /// If [httpClient] is given the caller owns it; otherwise [close] closes
  /// the internally created one.
  LeopardApiClient({
    required Uri baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
    bool allowInsecureHttp = false,
  }) : _baseUrl = baseUrl,
       _http = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null {
    final secure = baseUrl.scheme == 'https';
    if (!secure && !(allowInsecureHttp && baseUrl.scheme == 'http')) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'must use https');
    }
    if (baseUrl.host.isEmpty || baseUrl.hasQuery || baseUrl.hasFragment) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must be an origin with an optional path prefix',
      );
    }
  }

  final Uri _baseUrl;
  final http.Client _http;
  final bool _ownsHttpClient;

  /// Time allowed for each request, including reading the body.
  final Duration timeout;

  String? _sessionToken;

  /// Whether a session token is currently held.
  bool get hasSession => _sessionToken != null;

  /// Installs a session token obtained elsewhere (for example handed over
  /// from another isolate). Login methods on this class do this themselves.
  void useSession(SessionGrant session) {
    _sessionToken = session.token;
  }

  /// Forgets the session token without telling the server.
  void clearSession() {
    _sessionToken = null;
  }

  /// Forgets the session token and, if this object created its own HTTP
  /// client, closes it.
  void close() {
    _sessionToken = null;
    if (_ownsHttpClient) {
      _http.close();
    }
  }

  // ---- Health ----

  /// `GET /healthz`. Returns `true` for `200 {"status":"ok"}` and `false`
  /// for 503.
  Future<bool> health() async {
    final response = await _send('GET', const ['healthz']);
    if (response.statusCode == 503) {
      return false;
    }
    final body = _success(response);
    return body.string('status') == 'ok';
  }

  // ---- Setup ----

  /// `POST /v1/setup`: one-time vault initialisation from the phone.
  ///
  /// Sends the public parts of [material] only: KDF parameters, salt, both
  /// wrapped keys, both verifiers, the TOTP secret and the device public
  /// key. [setupToken] is required if the server was started with
  /// `LEOPARD_SETUP_TOKEN`.
  ///
  /// Errors: [ConflictException] `already_initialised`,
  /// [ForbiddenException] `setup_token_required`.
  Future<SetupResult> setup({
    required VaultSetupMaterial material,
    required String deviceLabel,
    String? setupToken,
  }) async {
    final response = await _send(
      'POST',
      const ['v1', 'setup'],
      headers: {'X-Leopard-Setup-Token': ?setupToken},
      body: {
        'kdf_params': material.kdfParams.toJson(),
        'salt': base64UrlEncodeNoPad(material.salt),
        'wrapped_vk_master': base64UrlEncodeNoPad(material.wrappedVkMaster),
        'wrapped_vk_recovery': base64UrlEncodeNoPad(material.wrappedVkRecovery),
        'master_auth_verifier': base64UrlEncodeNoPad(
          material.masterAuthVerifier,
        ),
        'recovery_auth_verifier': base64UrlEncodeNoPad(
          material.recoveryAuthVerifier,
        ),
        'totp_secret': base64UrlEncodeNoPad(material.totpSecret),
        'device': {
          'label': deviceLabel,
          'ed25519_pub': base64UrlEncodeNoPad(material.deviceKey.publicKey),
        },
      },
    );
    final body = _success(response);
    return SetupResult(
      deviceId: body.uuid('device_id'),
      createdAt: body.time('created_at'),
    );
  }

  // ---- Device login (mobile) ----

  /// `POST /v1/auth/device/challenge`. The server answers the same way for
  /// unknown devices, so success says nothing about the device id.
  Future<DeviceChallenge> deviceChallenge(String deviceId) async {
    _requireUuid(deviceId, 'deviceId');
    final response = await _send(
      'POST',
      const ['v1', 'auth', 'device', 'challenge'],
      body: {'device_id': deviceId},
    );
    final body = _success(response);
    return DeviceChallenge(
      nonce: body.bytes('nonce', deviceChallengeSize),
      expiresAt: body.time('expires_at'),
    );
  }

  /// `POST /v1/auth/device/verify`. [signature] is
  /// `LeopardCrypto.signDeviceAuth` over [nonce]. On success the mobile
  /// session token is installed in this client.
  ///
  /// Errors: [UnauthorizedException] `device_auth_failed` for every failure.
  /// The nonce is consumed either way; request a new challenge to retry.
  Future<SessionGrant> deviceVerify({
    required String deviceId,
    required Uint8List nonce,
    required Uint8List signature,
  }) async {
    _requireUuid(deviceId, 'deviceId');
    final response = await _send(
      'POST',
      const ['v1', 'auth', 'device', 'verify'],
      body: {
        'device_id': deviceId,
        'nonce': base64UrlEncodeNoPad(nonce),
        'signature': base64UrlEncodeNoPad(signature),
      },
    );
    final session = _sessionGrant(_success(response));
    _sessionToken = session.token;
    return session;
  }

  // ---- QR login ----

  /// `POST /v1/qr` (browser, no auth). [clientInfo] is an optional small
  /// JSON object shown to the user on the phone.
  ///
  /// The browser SHOULD check that [QrSession.verifyCode] and
  /// [QrSession.qrUri] equal the values it computes itself from
  /// [QrSession.sid] and its own public key.
  Future<QrSession> createQrSession({
    required Uint8List browserPub,
    Map<String, Object?>? clientInfo,
  }) async {
    final response = await _send(
      'POST',
      const ['v1', 'qr'],
      body: {
        'browser_pub': base64UrlEncodeNoPad(browserPub),
        'client_info': ?clientInfo,
      },
    );
    final body = _success(response);
    return QrSession(
      sid: body.bytes('sid', sidSize),
      pollToken: body.token('poll_token'),
      expiresAt: body.time('expires_at'),
      verifyCode: body.string('verify_code'),
      qrUri: body.string('qr_uri'),
    );
  }

  /// `GET /v1/qr/{sid}` (browser). Poll about once a second.
  ///
  /// Exactly one poll returns [QrPollApproved]; its web session token is
  /// installed in this client. The caller then decrypts the vault key with
  /// `LeopardCrypto.qrOpenVaultKey`.
  ///
  /// Errors: [NotFoundException] `qr_not_found` for an unknown `sid` or a
  /// wrong poll token.
  Future<QrPollResult> pollQrSession({
    required Uint8List sid,
    required String pollToken,
  }) async {
    final response = await _send(
      'GET',
      ['v1', 'qr', base64UrlEncodeNoPad(sid)],
      headers: {'X-Leopard-Poll-Token': pollToken},
    );
    final body = _success(response);
    final status = body.qrStatus('status');
    if (status != QrStatus.approved) {
      return QrPollWaiting(
        status: status,
        expiresAt: body.optionalTime('expires_at'),
      );
    }
    final approved = QrPollApproved(
      session: _sessionGrant(body),
      phoneEphPub: body.bytes('phone_eph_pub', x25519KeySize),
      nonce: body.bytes('nonce', nonceSize),
      ciphertext: body.bytes('ciphertext', qrCiphertextSize),
    );
    _sessionToken = approved.session.token;
    return approved;
  }

  /// `GET /v1/qr/{sid}/details` (mobile session).
  ///
  /// The phone MUST abort unless [QrDetails.browserPub] equals the key in
  /// the scanned QR code, and SHOULD compare [QrDetails.verifyCode] with
  /// the code it computes locally.
  Future<QrDetails> qrDetails(Uint8List sid) async {
    final response = await _send('GET', [
      'v1',
      'qr',
      base64UrlEncodeNoPad(sid),
      'details',
    ], authenticated: true);
    final body = _success(response);
    return QrDetails(
      sid: body.bytes('sid', sidSize),
      status: body.qrStatus('status'),
      browserPub: body.bytes('browser_pub', x25519KeySize),
      clientInfo: body.optionalObject('client_info'),
      ip: body.optionalString('ip') ?? '',
      createdAt: body.time('created_at'),
      expiresAt: body.time('expires_at'),
      verifyCode: body.string('verify_code'),
    );
  }

  /// `POST /v1/qr/{sid}/approve` (mobile session). [approval] comes from
  /// `LeopardCrypto.approveQrLogin`.
  ///
  /// Errors: [ForbiddenException] `bad_signature`, [GoneException]
  /// `qr_expired`, [ConflictException] `qr_not_pending`,
  /// [NotFoundException] `qr_not_found`.
  Future<QrApproveResult> approveQr({
    required Uint8List sid,
    required QrApproval approval,
  }) async {
    final response = await _send(
      'POST',
      ['v1', 'qr', base64UrlEncodeNoPad(sid), 'approve'],
      authenticated: true,
      body: {
        'phone_eph_pub': base64UrlEncodeNoPad(approval.phoneEphPub),
        'nonce': base64UrlEncodeNoPad(approval.nonce),
        'ciphertext': base64UrlEncodeNoPad(approval.ciphertext),
        'signature': base64UrlEncodeNoPad(approval.signature),
      },
    );
    final body = _success(response);
    return QrApproveResult(webSessionId: body.uuid('session_id'));
  }

  /// `POST /v1/qr/{sid}/reject` (mobile session).
  Future<void> rejectQr(Uint8List sid) async {
    final response = await _send('POST', [
      'v1',
      'qr',
      base64UrlEncodeNoPad(sid),
      'reject',
    ], authenticated: true);
    _success(response);
  }

  // ---- Emergency web login ----

  /// `GET /v1/auth/master/params` (no auth, hard rate limit).
  ///
  /// The returned parameters have already passed [KdfParams.validate]; a
  /// server offering weaker ones produces a [MalformedResponseException].
  ///
  /// Errors: [NotFoundException] `not_initialised`.
  Future<MasterParams> masterParams() async {
    final response = await _send('GET', const [
      'v1',
      'auth',
      'master',
      'params',
    ]);
    final body = _success(response);
    final params = body.kdfParams('kdf_params');
    return MasterParams(
      kdfParams: params,
      salt: body.bytes('salt', params.saltLength),
    );
  }

  /// `POST /v1/auth/master/login`. [proof] is the master auth key
  /// (`LeopardCrypto.masterAuthKey`); wipe it after this call. On success
  /// the web session token is installed in this client.
  ///
  /// Errors: [UnauthorizedException] `invalid_credentials` (identical
  /// whether the proof, the code or both were wrong),
  /// [RateLimitedException].
  Future<MasterLoginResult> masterLogin({
    required String totpCode,
    required Uint8List proof,
    Map<String, Object?>? clientInfo,
  }) async {
    final response = await _send(
      'POST',
      const ['v1', 'auth', 'master', 'login'],
      body: {
        'totp_code': totpCode,
        'proof': base64UrlEncodeNoPad(proof),
        'client_info': ?clientInfo,
      },
    );
    final body = _success(response);
    final result = MasterLoginResult(
      session: _sessionGrant(body),
      wrappedVkMaster: body.bytes('wrapped_vk_master', wrappedVkSize),
    );
    _sessionToken = result.session.token;
    return result;
  }

  // ---- Recovery ----

  /// `POST /v1/recovery/register-device`. [proof] is the recovery auth key
  /// (`LeopardCrypto.recoveryAuthKey`). **Revokes every existing device and
  /// session.** The new phone then logs in with [deviceChallenge] and
  /// [deviceVerify].
  ///
  /// Errors: [UnauthorizedException] `invalid_credentials`,
  /// [RateLimitedException].
  Future<RecoveryResult> recoveryRegisterDevice({
    required Uint8List proof,
    required String deviceLabel,
    required Uint8List devicePublicKey,
  }) async {
    final response = await _send(
      'POST',
      const ['v1', 'recovery', 'register-device'],
      body: {
        'proof': base64UrlEncodeNoPad(proof),
        'device': {
          'label': deviceLabel,
          'ed25519_pub': base64UrlEncodeNoPad(devicePublicKey),
        },
      },
    );
    final body = _success(response);
    final params = body.kdfParams('kdf_params');
    return RecoveryResult(
      deviceId: body.uuid('device_id'),
      wrappedVkRecovery: body.bytes('wrapped_vk_recovery', wrappedVkSize),
      kdfParams: params,
      salt: body.bytes('salt', params.saltLength),
    );
  }

  // ---- Items (any session) ----

  /// `GET /v1/items`. Returns items changed strictly after [since]
  /// (including tombstones), ordered by `updated_at`. Omit [since] for a
  /// full sync; afterwards pass the previous [ItemsPage.serverTime]
  /// verbatim.
  Future<ItemsPage> listItems({String? since}) async {
    final response = await _send(
      'GET',
      const ['v1', 'items'],
      query: {'since': ?since},
      authenticated: true,
    );
    final body = _success(response);
    return ItemsPage(
      items: [for (final item in body.objects('items')) _remoteItem(item)],
      serverTime: body.string('server_time'),
    );
  }

  /// `PUT /v1/items/{id}`: create ([expectedVersion] 0) or replace.
  ///
  /// The stored version becomes `expectedVersion + 1`, and **that** is the
  /// version the ciphertext must have been sealed for.
  ///
  /// Errors: [ConflictException] `version_conflict` with the server's
  /// current version (nothing was written), [NotFoundException]
  /// `item_not_found`, [GoneException] `item_deleted`.
  Future<ItemMeta> putItem({
    required String id,
    required SealedItem sealed,
    required int expectedVersion,
  }) async {
    _requireUuid(id, 'id');
    if (expectedVersion < 0) {
      throw RangeError.range(expectedVersion, 0, null, 'expectedVersion');
    }
    final response = await _send(
      'PUT',
      ['v1', 'items', id],
      authenticated: true,
      body: {
        'ciphertext': base64UrlEncodeNoPad(sealed.ciphertext),
        'nonce': base64UrlEncodeNoPad(sealed.nonce),
        'expected_version': expectedVersion,
      },
    );
    return _itemMeta(_success(response));
  }

  /// `DELETE /v1/items/{id}`: soft delete, leaving a tombstone with
  /// `expectedVersion + 1`.
  ///
  /// Errors: as for [putItem].
  Future<ItemMeta> deleteItem({
    required String id,
    required int expectedVersion,
  }) async {
    _requireUuid(id, 'id');
    if (expectedVersion < 1) {
      throw RangeError.range(expectedVersion, 1, null, 'expectedVersion');
    }
    final response = await _send(
      'DELETE',
      ['v1', 'items', id],
      authenticated: true,
      body: {'expected_version': expectedVersion},
    );
    return _itemMeta(_success(response));
  }

  // ---- Sessions ----

  /// `POST /v1/sessions/heartbeat` (any session). For a web session this is
  /// the only request that resets the idle timer.
  ///
  /// An [UnauthorizedException] with `sessionEnded` means: lock and wipe.
  Future<Heartbeat> heartbeat() async {
    final response = await _send('POST', const [
      'v1',
      'sessions',
      'heartbeat',
    ], authenticated: true);
    final body = _success(response);
    return Heartbeat(
      sessionId: body.uuid('session_id'),
      kind: body.sessionKind('kind'),
      idleTimeoutSeconds: body.integer('idle_timeout_seconds'),
      expiresAt: body.time('expires_at'),
      serverTime: body.time('server_time'),
    );
  }

  /// `POST /v1/sessions/logout` (any session). The local token is dropped
  /// whether or not the request succeeds.
  Future<void> logout() async {
    try {
      final response = await _send('POST', const [
        'v1',
        'sessions',
        'logout',
      ], authenticated: true);
      _success(response);
    } finally {
      _sessionToken = null;
    }
  }

  /// `GET /v1/sessions` (mobile session): live sessions, newest first.
  Future<List<SessionInfo>> listSessions() async {
    final response = await _send('GET', const [
      'v1',
      'sessions',
    ], authenticated: true);
    final body = _success(response);
    return [
      for (final s in body.objects('sessions'))
        SessionInfo(
          id: s.uuid('id'),
          kind: s.sessionKind('kind'),
          deviceId: s.optionalString('device_id'),
          clientInfo: s.optionalObject('client_info'),
          ip: s.optionalString('ip') ?? '',
          createdAt: s.time('created_at'),
          lastSeen: s.time('last_seen'),
          idleTimeoutSeconds: s.integer('idle_timeout_seconds'),
          expiresAt: s.time('expires_at'),
          current: s.boolean('current'),
        ),
    ];
  }

  /// `DELETE /v1/sessions/{id}` (mobile session): remote logout.
  ///
  /// Errors: [NotFoundException] `session_not_found`.
  Future<void> revokeSession(String sessionId) async {
    _requireUuid(sessionId, 'sessionId');
    final response = await _send('DELETE', [
      'v1',
      'sessions',
      sessionId,
    ], authenticated: true);
    _success(response);
  }

  // ---- Audit log ----

  /// `GET /v1/audit` (mobile session): newest first. [limit] is 1 to 500.
  /// Pass the previous [AuditPage.nextBefore] as [before] for the next
  /// page.
  Future<AuditPage> auditLog({int limit = 100, int? before}) async {
    if (limit < 1 || limit > 500) {
      throw RangeError.range(limit, 1, 500, 'limit');
    }
    if (before != null && before < 1) {
      throw RangeError.range(before, 1, null, 'before');
    }
    final response = await _send(
      'GET',
      const ['v1', 'audit'],
      query: {'limit': '$limit', 'before': ?before?.toString()},
      authenticated: true,
    );
    final body = _success(response);
    return AuditPage(
      entries: [
        for (final e in body.objects('entries'))
          AuditEntry(
            id: e.integer('id'),
            timestamp: e.time('ts'),
            event: e.string('event'),
            sessionId: e.optionalString('session_id'),
            deviceId: e.optionalString('device_id'),
            ip: e.optionalString('ip'),
            meta: e.optionalObject('meta'),
          ),
      ],
      nextBefore: body.optionalInteger('next_before'),
    );
  }

  // ---- Transport ----

  Future<http.Response> _send(
    String method,
    List<String> path, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    Map<String, Object?>? body,
    bool authenticated = false,
  }) async {
    final token = _sessionToken;
    if (authenticated && token == null) {
      throw StateError('no session: log in before calling this endpoint');
    }
    final uri = _baseUrl.replace(
      pathSegments: [
        ..._baseUrl.pathSegments.where((s) => s.isNotEmpty),
        ...path,
      ],
      queryParameters: query.isEmpty ? null : query,
    );
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json'
      ..headers.addAll(headers);
    if (authenticated) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request
        ..headers['Content-Type'] = 'application/json'
        ..bodyBytes = utf8.encode(jsonEncode(body));
    }
    Future<http.Response> exchange() async =>
        http.Response.fromStream(await _http.send(request));
    final response = await exchange().timeout(timeout);
    if (response.statusCode == 401 &&
        authenticated &&
        identical(token, _sessionToken)) {
      // The session is gone. Drop the token; the caller must lock.
      _sessionToken = null;
    }
    return response;
  }

  /// Returns the body of a 2xx response as a JSON object, or throws the
  /// [ApiException] for the status.
  _Json _success(http.Response response) {
    final status = response.statusCode;
    final requestId = response.headers['x-request-id'];
    final Map<String, Object?>? json = _decodeObject(response);
    if (status >= 200 && status < 300) {
      if (json == null) {
        throw MalformedResponseException(
          statusCode: status,
          message: 'response body is not a JSON object',
          requestId: requestId,
        );
      }
      return _Json(json, status, requestId);
    }
    throw _error(response, json, requestId);
  }

  ApiException _error(
    http.Response response,
    Map<String, Object?>? json,
    String? requestId,
  ) {
    final status = response.statusCode;
    final error = json?['error'];
    var code = 'unknown';
    var message = 'HTTP $status';
    if (error is Map<String, Object?>) {
      final c = error['code'];
      final m = error['message'];
      if (c is String) code = c;
      if (m is String) message = m;
    }
    ItemMeta? current;
    final rawCurrent = json?['current'];
    if (rawCurrent is Map<String, Object?>) {
      try {
        current = _itemMeta(_Json(rawCurrent, status, requestId));
      } on MalformedResponseException {
        current = null;
      }
    }
    return switch (status) {
      400 => BadRequestException(
        statusCode: status,
        code: code,
        message: message,
        requestId: requestId,
      ),
      401 => UnauthorizedException(
        statusCode: status,
        code: code,
        message: message,
        requestId: requestId,
      ),
      403 => ForbiddenException(
        statusCode: status,
        code: code,
        message: message,
        requestId: requestId,
      ),
      404 => NotFoundException(
        statusCode: status,
        code: code,
        message: message,
        requestId: requestId,
      ),
      409 => ConflictException(
        statusCode: status,
        code: code,
        message: message,
        requestId: requestId,
        current: current,
      ),
      410 => GoneException(
        statusCode: status,
        code: code,
        message: message,
        requestId: requestId,
        current: current,
      ),
      413 => PayloadTooLargeException(
        statusCode: status,
        code: code,
        message: message,
        requestId: requestId,
      ),
      429 => RateLimitedException(
        statusCode: status,
        code: code,
        message: message,
        requestId: requestId,
        retryAfter: _retryAfter(response.headers['retry-after']),
      ),
      >= 500 => ServerException(
        statusCode: status,
        code: code,
        message: message,
        requestId: requestId,
      ),
      _ => UnexpectedStatusException(
        statusCode: status,
        code: code,
        message: message,
        requestId: requestId,
      ),
    };
  }

  static Map<String, Object?>? _decodeObject(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// `Retry-After` as delay seconds. The server always sends seconds; an
  /// HTTP-date (allowed by the RFC, possible from a proxy) is ignored.
  static Duration? _retryAfter(String? header) {
    if (header == null) {
      return null;
    }
    final seconds = int.tryParse(header.trim());
    if (seconds == null || seconds < 0) {
      return null;
    }
    return Duration(seconds: seconds);
  }

  static void _requireUuid(String value, String name) {
    if (!isCanonicalUuid(value)) {
      throw ArgumentError.value(
        value,
        name,
        'must be a canonical lower-case UUID',
      );
    }
  }

  static SessionGrant _sessionGrant(_Json body) => SessionGrant(
    token: body.token('session_token'),
    sessionId: body.uuid('session_id'),
    kind: body.sessionKind('kind'),
    idleTimeoutSeconds: body.integer('idle_timeout_seconds'),
  );

  static ItemMeta _itemMeta(_Json body) => ItemMeta(
    id: body.uuid('id'),
    version: body.integer('version'),
    updatedAt: body.time('updated_at'),
    deleted: body.boolean('deleted'),
  );

  static RemoteItem _remoteItem(_Json body) {
    final deleted = body.boolean('deleted');
    return RemoteItem(
      id: body.uuid('id'),
      version: body.integer('version'),
      updatedAt: body.time('updated_at'),
      deleted: deleted,
      ciphertext: deleted ? null : body.bytes('ciphertext', null),
      nonce: deleted ? null : body.bytes('nonce', nonceSize),
      deletedAt: body.optionalTime('deleted_at'),
    );
  }
}

/// Typed, checked access to a JSON object from a response. Every mismatch
/// is a [MalformedResponseException]; messages name the field, never its
/// value.
final class _Json {
  _Json(this._map, this._status, this._requestId);

  final Map<String, Object?> _map;
  final int _status;
  final String? _requestId;

  MalformedResponseException _bad(String key, String expected) =>
      MalformedResponseException(
        statusCode: _status,
        message: 'response field "$key" must be $expected',
        requestId: _requestId,
      );

  String string(String key) {
    final value = _map[key];
    if (value is String) return value;
    throw _bad(key, 'a string');
  }

  String? optionalString(String key) {
    final value = _map[key];
    if (value == null || value is String) return value as String?;
    throw _bad(key, 'a string or null');
  }

  int integer(String key) {
    final value = _map[key];
    if (value is int) return value;
    throw _bad(key, 'an integer');
  }

  int? optionalInteger(String key) {
    final value = _map[key];
    if (value == null || value is int) return value as int?;
    throw _bad(key, 'an integer or null');
  }

  bool boolean(String key) {
    final value = _map[key];
    if (value is bool) return value;
    throw _bad(key, 'a boolean');
  }

  String uuid(String key) {
    final value = _map[key];
    if (value is String && isCanonicalUuid(value)) return value;
    throw _bad(key, 'a canonical UUID');
  }

  DateTime time(String key) {
    final value = optionalTime(key);
    if (value != null) return value;
    throw _bad(key, 'an RFC 3339 timestamp');
  }

  DateTime? optionalTime(String key) {
    final value = _map[key];
    if (value == null) return null;
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null && parsed.isUtc) return parsed;
    }
    throw _bad(key, 'an RFC 3339 timestamp');
  }

  /// A base64url field of exactly [size] bytes (any size if `null`).
  Uint8List bytes(String key, int? size) {
    final value = _map[key];
    if (value is String) {
      try {
        final decoded = base64UrlDecodeNoPad(value);
        if (size == null || decoded.length == size) return decoded;
      } on InvalidFormatException {
        // Fall through to the error below.
      }
    }
    throw _bad(key, size == null ? 'base64url' : 'base64url of $size bytes');
  }

  /// A session or poll token: kept as text, but it must be base64url of 32
  /// bytes.
  String token(String key) {
    bytes(key, tokenSize);
    return _map[key]! as String;
  }

  Map<String, Object?> optionalObject(String key) {
    final value = _map[key];
    if (value == null) return const {};
    if (value is Map<String, Object?>) return value;
    throw _bad(key, 'an object or null');
  }

  List<_Json> objects(String key) {
    final value = _map[key];
    if (value is List<Object?>) {
      return [
        for (final element in value)
          if (element is Map<String, Object?>)
            _Json(element, _status, _requestId)
          else
            throw _bad(key, 'a list of objects'),
      ];
    }
    throw _bad(key, 'a list of objects');
  }

  SessionKind sessionKind(String key) {
    final value = _map[key];
    for (final kind in SessionKind.values) {
      if (kind.wireName == value) return kind;
    }
    throw _bad(key, 'a session kind');
  }

  QrStatus qrStatus(String key) {
    final value = _map[key];
    for (final status in QrStatus.values) {
      if (status.wireName == value) return status;
    }
    throw _bad(key, 'a QR status');
  }

  KdfParams kdfParams(String key) {
    final value = _map[key];
    if (value is Map<String, Object?>) {
      try {
        return KdfParams.fromJson(value)..validate();
      } on InvalidKdfParamsException catch (e) {
        throw MalformedResponseException(
          statusCode: _status,
          message: 'server sent unacceptable KDF parameters: ${e.message}',
          requestId: _requestId,
        );
      }
    }
    throw _bad(key, 'an object');
  }
}
