import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:leopard_core/leopard_core.dart';

import '../error/failures.dart';

/// The server calls the web app makes (a subset of `docs/api.md`).
///
/// The session token is held by the implementation, in memory only. Callers
/// never see it.
abstract interface class LeopardApi {
  /// Whether a session token is held.
  bool get hasSession;

  /// Fires when the server answers an authenticated request with a 401 that
  /// means the session is gone (revoked, expired, unknown token). The token
  /// has already been dropped; the listener must wipe the vault key.
  Stream<UnauthorizedException> get sessionEnded;

  /// `POST /v1/qr`.
  Future<QrSession> createQrSession({
    required Uint8List browserPub,
    Map<String, Object?>? clientInfo,
  });

  /// `GET /v1/qr/{sid}`. The one approved poll installs the session token.
  Future<QrPollResult> pollQrSession({
    required Uint8List sid,
    required String pollToken,
  });

  /// `GET /v1/auth/master/params`. The parameters are already validated
  /// against the v1 minimum.
  Future<MasterParams> masterParams();

  /// `POST /v1/auth/master/login`. Success installs the session token.
  Future<MasterLoginResult> masterLogin({
    required String totpCode,
    required Uint8List proof,
    Map<String, Object?>? clientInfo,
  });

  /// `GET /v1/items`.
  Future<ItemsPage> listItems({String? since});

  /// `PUT /v1/items/{id}`.
  Future<ItemMeta> putItem({
    required String id,
    required SealedItem sealed,
    required int expectedVersion,
  });

  /// `DELETE /v1/items/{id}`.
  Future<ItemMeta> deleteItem({
    required String id,
    required int expectedVersion,
  });

  /// `POST /v1/sessions/heartbeat`: the only request that resets the
  /// server's idle timer for a web session.
  Future<Heartbeat> heartbeat();

  /// `POST /v1/sessions/logout`. The token is dropped whether or not the
  /// request succeeds.
  Future<void> logout();

  /// Forgets the token without telling the server.
  void clearSession();
}

/// [LeopardApi] on `leopard_core`'s [LeopardApiClient].
final class HttpLeopardApi implements LeopardApi {
  HttpLeopardApi({
    required Uri baseUrl,
    bool allowInsecureHttp = false,
    http.Client? httpClient,
  }) : _client = LeopardApiClient(
         baseUrl: baseUrl,
         allowInsecureHttp: allowInsecureHttp,
         httpClient: httpClient,
       );

  final LeopardApiClient _client;
  final StreamController<UnauthorizedException> _sessionEnded =
      StreamController<UnauthorizedException>.broadcast();

  /// The logout request still on its way, if any. The client drops its
  /// token when that request completes, so a login must not install a new
  /// token before then.
  Future<void>? _logoutInFlight;

  @override
  bool get hasSession => _client.hasSession;

  @override
  Stream<UnauthorizedException> get sessionEnded => _sessionEnded.stream;

  /// Runs a request that needs the session token.
  ///
  /// Without a token (the app locked while a screen was still open) nothing
  /// is sent. A 401 that ends the session is announced on [sessionEnded]
  /// before it is rethrown, so the vault key is wiped whichever screen made
  /// the request.
  Future<T> _authenticated<T>(Future<T> Function() request) async {
    if (!_client.hasSession) {
      throw const VaultLockedFailure();
    }
    try {
      return await request();
    } on UnauthorizedException catch (e) {
      if (e.sessionEnded) {
        _client.clearSession();
        _sessionEnded.add(e);
      }
      rethrow;
    }
  }

  @override
  Future<QrSession> createQrSession({
    required Uint8List browserPub,
    Map<String, Object?>? clientInfo,
  }) => _client.createQrSession(browserPub: browserPub, clientInfo: clientInfo);

  @override
  Future<QrPollResult> pollQrSession({
    required Uint8List sid,
    required String pollToken,
  }) async {
    await _logoutInFlight;
    return _client.pollQrSession(sid: sid, pollToken: pollToken);
  }

  @override
  Future<MasterParams> masterParams() => _client.masterParams();

  @override
  Future<MasterLoginResult> masterLogin({
    required String totpCode,
    required Uint8List proof,
    Map<String, Object?>? clientInfo,
  }) async {
    await _logoutInFlight;
    return _client.masterLogin(
      totpCode: totpCode,
      proof: proof,
      clientInfo: clientInfo,
    );
  }

  @override
  Future<ItemsPage> listItems({String? since}) =>
      _authenticated(() => _client.listItems(since: since));

  @override
  Future<ItemMeta> putItem({
    required String id,
    required SealedItem sealed,
    required int expectedVersion,
  }) => _authenticated(
    () => _client.putItem(
      id: id,
      sealed: sealed,
      expectedVersion: expectedVersion,
    ),
  );

  @override
  Future<ItemMeta> deleteItem({
    required String id,
    required int expectedVersion,
  }) => _authenticated(
    () => _client.deleteItem(id: id, expectedVersion: expectedVersion),
  );

  @override
  Future<Heartbeat> heartbeat() => _authenticated(_client.heartbeat);

  @override
  Future<void> logout() async {
    if (!_client.hasSession) {
      return;
    }
    final request = _client.logout();
    final settled = request.then<void>((_) {}, onError: (Object _) {});
    _logoutInFlight = settled;
    unawaited(
      settled.whenComplete(() {
        if (identical(_logoutInFlight, settled)) {
          _logoutInFlight = null;
        }
      }),
    );
    await request;
  }

  @override
  void clearSession() => _client.clearSession();

  /// Drops the token and closes the HTTP client.
  Future<void> dispose() async {
    _client.close();
    await _sessionEnded.close();
  }
}
