import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

import '../error/failures.dart';
import '../session/vault_session.dart';

/// Creates the HTTP client for a server. Replaced in tests.
typedef ApiClientFactory = LeopardApiClient Function(Uri serverUrl);

LeopardApiClient defaultApiClientFactory(Uri serverUrl) =>
    LeopardApiClient(baseUrl: serverUrl);

/// The authenticated server operations the features need.
///
/// Implementations log the phone in with its device key when needed, so
/// callers never deal with session tokens.
abstract interface class RemoteVault {
  Future<ItemsPage> listItems({String? since});

  Future<ItemMeta> putItem({
    required String id,
    required SealedItem sealed,
    required int expectedVersion,
  });

  Future<ItemMeta> deleteItem({
    required String id,
    required int expectedVersion,
  });

  Future<QrDetails> qrDetails(Uint8List sid);

  Future<QrApproveResult> approveQr({
    required Uint8List sid,
    required QrApproval approval,
  });

  Future<void> rejectQr(Uint8List sid);

  Future<List<SessionInfo>> listSessions();

  Future<void> revokeSession(String sessionId);

  Future<AuditPage> auditLog({int limit, int? before});

  /// Forgets the session token (on lock). The server session stays valid
  /// until it idles out; the next call logs in again.
  void forgetSession();

  /// Points the client at a server. Called after setup and at unlock.
  void configure(Uri serverUrl);
}

/// [RemoteVault] on [LeopardApiClient], with device login (crypto-spec §9).
///
/// A mobile session lasts 24 h without use. When the server answers 401 the
/// phone signs a fresh challenge once and repeats the request. If the device
/// login itself is refused the phone has been revoked: [DeviceRevokedFailure].
final class ApiRemoteVault implements RemoteVault {
  ApiRemoteVault({
    required VaultSession session,
    required LeopardCrypto crypto,
    ApiClientFactory clientFactory = defaultApiClientFactory,
  }) : _session = session,
       _crypto = crypto,
       _clientFactory = clientFactory;

  final VaultSession _session;
  final LeopardCrypto _crypto;
  final ApiClientFactory _clientFactory;

  LeopardApiClient? _client;
  Uri? _serverUrl;
  Future<void>? _loginInFlight;

  @override
  void configure(Uri serverUrl) {
    if (_serverUrl == serverUrl && _client != null) {
      return;
    }
    _client?.close();
    _client = _clientFactory(serverUrl);
    _serverUrl = serverUrl;
  }

  @override
  void forgetSession() => _client?.clearSession();

  LeopardApiClient get _api =>
      _client ?? (throw StateError('RemoteVault is not configured'));

  Future<void> _login() {
    return _loginInFlight ??= _doLogin().whenComplete(() {
      _loginInFlight = null;
    });
  }

  Future<void> _doLogin() async {
    final vault = _session.require;
    final api = _api;
    try {
      final challenge = await api.deviceChallenge(vault.deviceId);
      final signature = await _crypto.signDeviceAuth(
        deviceSeed: vault.deviceSeed,
        deviceId: vault.deviceId,
        challenge: challenge.nonce,
      );
      await api.deviceVerify(
        deviceId: vault.deviceId,
        nonce: challenge.nonce,
        signature: signature,
      );
    } on UnauthorizedException catch (e) {
      if (e.code == 'device_auth_failed') {
        throw const DeviceRevokedFailure();
      }
      rethrow;
    }
  }

  Future<T> _authenticated<T>(
    Future<T> Function(LeopardApiClient api) request,
  ) async {
    final api = _api;
    if (!api.hasSession) {
      await _login();
    }
    try {
      return await request(api);
    } on UnauthorizedException catch (e) {
      if (!e.sessionEnded) {
        rethrow;
      }
      await _login();
      return request(api);
    }
  }

  @override
  Future<ItemsPage> listItems({String? since}) =>
      _authenticated((api) => api.listItems(since: since));

  @override
  Future<ItemMeta> putItem({
    required String id,
    required SealedItem sealed,
    required int expectedVersion,
  }) => _authenticated(
    (api) =>
        api.putItem(id: id, sealed: sealed, expectedVersion: expectedVersion),
  );

  @override
  Future<ItemMeta> deleteItem({
    required String id,
    required int expectedVersion,
  }) => _authenticated(
    (api) => api.deleteItem(id: id, expectedVersion: expectedVersion),
  );

  @override
  Future<QrDetails> qrDetails(Uint8List sid) =>
      _authenticated((api) => api.qrDetails(sid));

  @override
  Future<QrApproveResult> approveQr({
    required Uint8List sid,
    required QrApproval approval,
  }) => _authenticated((api) => api.approveQr(sid: sid, approval: approval));

  @override
  Future<void> rejectQr(Uint8List sid) =>
      _authenticated((api) => api.rejectQr(sid));

  @override
  Future<List<SessionInfo>> listSessions() =>
      _authenticated((api) => api.listSessions());

  @override
  Future<void> revokeSession(String sessionId) =>
      _authenticated((api) => api.revokeSession(sessionId));

  @override
  Future<AuditPage> auditLog({int limit = 100, int? before}) =>
      _authenticated((api) => api.auditLog(limit: limit, before: before));
}
