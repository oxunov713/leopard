import 'dart:typed_data';

import '../crypto/kdf_params.dart';

/// Kind of session a token belongs to.
enum SessionKind {
  /// Obtained by device login. May call every endpoint.
  mobile('mobile'),

  /// Obtained by QR login or master-password login.
  web('web');

  const SessionKind(this.wireName);

  /// The value used on the wire.
  final String wireName;
}

/// State of a QR login request.
enum QrStatus {
  pending('pending'),
  approved('approved'),
  rejected('rejected'),
  expired('expired'),
  consumed('consumed');

  const QrStatus(this.wireName);

  /// The value used on the wire.
  final String wireName;
}

/// Response of `POST /v1/setup`.
final class SetupResult {
  const SetupResult({required this.deviceId, required this.createdAt});

  /// The server-assigned id of the first device.
  final String deviceId;
  final DateTime createdAt;
}

/// Response of `POST /v1/auth/device/challenge`.
final class DeviceChallenge {
  const DeviceChallenge({required this.nonce, required this.expiresAt});

  /// 32-byte single-use challenge to sign.
  final Uint8List nonce;
  final DateTime expiresAt;
}

/// A freshly issued session.
final class SessionGrant {
  const SessionGrant({
    required this.token,
    required this.sessionId,
    required this.kind,
    required this.idleTimeoutSeconds,
  });

  /// The bearer token (base64url of 32 bytes). A secret: keep it in memory
  /// only.
  final String token;
  final String sessionId;
  final SessionKind kind;
  final int idleTimeoutSeconds;

  @override
  String toString() => 'SessionGrant($sessionId, ${kind.wireName})';
}

/// Response of `POST /v1/qr` (browser side).
final class QrSession {
  const QrSession({
    required this.sid,
    required this.pollToken,
    required this.expiresAt,
    required this.verifyCode,
    required this.qrUri,
  });

  /// 16-byte session id.
  final Uint8List sid;

  /// Secret needed to collect the result. Memory only; never put it in the
  /// QR code.
  final String pollToken;
  final DateTime expiresAt;

  /// The server's idea of the verification code. Compute it locally and
  /// compare.
  final String verifyCode;

  /// The server's idea of the QR text. Build it locally and compare.
  final String qrUri;

  @override
  String toString() => 'QrSession(expiresAt: $expiresAt)';
}

/// Result of polling `GET /v1/qr/{sid}`.
sealed class QrPollResult {
  const QrPollResult();

  QrStatus get status;
}

/// The request is still pending, or ended without a session
/// (`rejected`, `expired`, `consumed`).
final class QrPollWaiting extends QrPollResult {
  const QrPollWaiting({required this.status, this.expiresAt});

  @override
  final QrStatus status;
  final DateTime? expiresAt;
}

/// The phone approved. Returned by exactly one poll.
final class QrPollApproved extends QrPollResult {
  const QrPollApproved({
    required this.session,
    required this.phoneEphPub,
    required this.nonce,
    required this.ciphertext,
  });

  /// The new web session.
  final SessionGrant session;

  /// The phone's ephemeral X25519 public key, 32 bytes.
  final Uint8List phoneEphPub;

  /// 12 bytes.
  final Uint8List nonce;

  /// The encrypted vault key, 48 bytes.
  final Uint8List ciphertext;

  @override
  QrStatus get status => QrStatus.approved;
}

/// Response of `GET /v1/qr/{sid}/details` (phone side).
final class QrDetails {
  const QrDetails({
    required this.sid,
    required this.status,
    required this.browserPub,
    required this.clientInfo,
    required this.ip,
    required this.createdAt,
    required this.expiresAt,
    required this.verifyCode,
  });

  final Uint8List sid;
  final QrStatus status;

  /// The browser key **as reported by the server**. The phone MUST take the
  /// key from the QR code and abort if this differs.
  final Uint8List browserPub;

  /// Untrusted, display-only description of the requesting browser.
  final Map<String, Object?> clientInfo;
  final String ip;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String verifyCode;
}

/// Response of `POST /v1/qr/{sid}/approve`.
final class QrApproveResult {
  const QrApproveResult({required this.webSessionId});

  /// The web session that becomes active when the browser collects it. The
  /// phone can revoke it with `DELETE /v1/sessions/{id}`.
  final String webSessionId;
}

/// Response of `GET /v1/auth/master/params`.
final class MasterParams {
  const MasterParams({required this.kdfParams, required this.salt});

  /// Already validated against the v1 minimum by the client.
  final KdfParams kdfParams;

  /// 16-byte Argon2id salt.
  final Uint8List salt;
}

/// Response of `POST /v1/auth/master/login`.
final class MasterLoginResult {
  const MasterLoginResult({
    required this.session,
    required this.wrappedVkMaster,
  });

  final SessionGrant session;

  /// 60 bytes; unwrap with the KEK.
  final Uint8List wrappedVkMaster;
}

/// Response of `POST /v1/recovery/register-device`.
final class RecoveryResult {
  const RecoveryResult({
    required this.deviceId,
    required this.wrappedVkRecovery,
    required this.kdfParams,
    required this.salt,
  });

  /// The id of the newly registered device.
  final String deviceId;

  /// 60 bytes; unwrap with the recovery KEK.
  final Uint8List wrappedVkRecovery;

  /// Already validated against the v1 minimum by the client.
  final KdfParams kdfParams;
  final Uint8List salt;
}

/// An item's server-side metadata.
final class ItemMeta {
  const ItemMeta({
    required this.id,
    required this.version,
    required this.updatedAt,
    required this.deleted,
  });

  final String id;

  /// The stored version; the one bound into the AEAD associated data.
  final int version;
  final DateTime updatedAt;
  final bool deleted;

  @override
  String toString() => 'ItemMeta($id v$version${deleted ? ' deleted' : ''})';
}

/// An item as returned by `GET /v1/items`: ciphertext, or a tombstone.
final class RemoteItem extends ItemMeta {
  const RemoteItem({
    required super.id,
    required super.version,
    required super.updatedAt,
    required super.deleted,
    this.ciphertext,
    this.nonce,
    this.deletedAt,
  });

  /// `ciphertext || tag`; `null` for a tombstone.
  final Uint8List? ciphertext;

  /// 12-byte nonce; `null` for a tombstone.
  final Uint8List? nonce;

  /// Set for a tombstone.
  final DateTime? deletedAt;
}

/// Response of `GET /v1/items`.
final class ItemsPage {
  const ItemsPage({required this.items, required this.serverTime});

  final List<RemoteItem> items;

  /// Opaque cursor: store it verbatim and pass it as `since` next time. It
  /// is kept as text because it has microsecond precision, which a
  /// `DateTime` cannot hold on the web.
  final String serverTime;
}

/// Response of `POST /v1/sessions/heartbeat`.
final class Heartbeat {
  const Heartbeat({
    required this.sessionId,
    required this.kind,
    required this.idleTimeoutSeconds,
    required this.expiresAt,
    required this.serverTime,
  });

  final String sessionId;
  final SessionKind kind;
  final int idleTimeoutSeconds;
  final DateTime expiresAt;
  final DateTime serverTime;
}

/// A live session, from `GET /v1/sessions`.
final class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.kind,
    required this.deviceId,
    required this.clientInfo,
    required this.ip,
    required this.createdAt,
    required this.lastSeen,
    required this.idleTimeoutSeconds,
    required this.expiresAt,
    required this.current,
  });

  final String id;
  final SessionKind kind;

  /// The device that owns (mobile) or approved (web, QR login) the session;
  /// `null` for a web session created by master-password login.
  final String? deviceId;

  /// Untrusted, display-only.
  final Map<String, Object?> clientInfo;
  final String ip;
  final DateTime createdAt;
  final DateTime lastSeen;
  final int idleTimeoutSeconds;
  final DateTime expiresAt;

  /// Whether this is the session making the request.
  final bool current;
}

/// One audit log entry, from `GET /v1/audit`.
final class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.timestamp,
    required this.event,
    required this.sessionId,
    required this.deviceId,
    required this.ip,
    required this.meta,
  });

  final int id;
  final DateTime timestamp;

  /// For example `qr_approved`, `master_login_failed`.
  final String event;
  final String? sessionId;
  final String? deviceId;
  final String? ip;
  final Map<String, Object?> meta;
}

/// Response of `GET /v1/audit`.
final class AuditPage {
  const AuditPage({required this.entries, required this.nextBefore});

  /// Newest first.
  final List<AuditEntry> entries;

  /// Pass as `before` for the next page; `null` when there is no more.
  final int? nextBefore;
}
