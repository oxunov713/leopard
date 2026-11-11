import 'package:leopard_core/leopard_core.dart';

import '../../../core/network/remote_vault.dart';
import '../../../core/security/biometric_authenticator.dart';
import '../../../core/session/vault_session.dart';
import '../domain/qr_login_repository.dart';

final class QrLoginRepositoryImpl implements QrLoginRepository {
  QrLoginRepositoryImpl({
    required RemoteVault remote,
    required VaultSession session,
    required BiometricAuthenticator biometrics,
    required LeopardCrypto crypto,
    DateTime Function() now = DateTime.now,
  }) : _remote = remote,
       _session = session,
       _biometrics = biometrics,
       _crypto = crypto,
       _now = now;

  final RemoteVault _remote;
  final VaultSession _session;
  final BiometricAuthenticator _biometrics;
  final LeopardCrypto _crypto;
  final DateTime Function() _now;

  @override
  Future<QrLoginRequest> load(String scannedText) async {
    final QrUri scanned;
    try {
      scanned = QrUri.parse(scannedText.trim());
    } on LeopardCryptoException {
      throw const QrRejectedFailure('This is not a Leopard login code.');
    }
    // The code the user compares is computed here, from the QR code alone.
    final code = await _crypto.verifyCode(
      sid: scanned.sid,
      browserPub: scanned.browserPub,
    );
    final QrDetails details;
    try {
      details = await _remote.qrDetails(scanned.sid);
    } on NotFoundException {
      throw const QrRejectedFailure(
        'The server does not know this login code. It may have expired.',
      );
    }
    // crypto-spec §10.1 step 4: abort if the server names another key.
    if (!constantTimeEquals(details.browserPub, scanned.browserPub) ||
        !constantTimeEquals(details.sid, scanned.sid)) {
      throw const QrRejectedFailure(
        'The server reported a different browser key than the QR code. '
        'The login was not approved.',
      );
    }
    if (!constantTimeEquals(details.verifyCode.codeUnits, code.codeUnits)) {
      throw const QrRejectedFailure(
        'The verification code from the server does not match. '
        'The login was not approved.',
      );
    }
    if (details.status != QrStatus.pending ||
        !details.expiresAt.isAfter(_now())) {
      throw const QrRejectedFailure(
        'This login code has expired or was already used. '
        'Reload the page in the browser and scan again.',
      );
    }
    final reported = details.clientInfo['reported'];
    final info = reported is Map<String, Object?>
        ? reported
        : const <String, Object?>{};
    return QrLoginRequest(
      sid: scanned.sid,
      browserPub: scanned.browserPub,
      verifyCode: code,
      ip: details.ip,
      browser: _text(info['browser']),
      platform: _text(info['platform']),
      userAgent: _text(details.clientInfo['user_agent']),
      createdAt: details.createdAt,
      expiresAt: details.expiresAt,
    );
  }

  @override
  Future<bool> confirmPresence() async {
    final outcome = await _biometrics.authenticate(
      reason: 'Approve the browser login',
    );
    return outcome == BiometricOutcome.success;
  }

  @override
  Future<void> approve(QrLoginRequest request) async {
    final vault = _session.require;
    final approval = await _crypto.approveQrLogin(
      vaultKey: vault.vaultKey,
      deviceSeed: vault.deviceSeed,
      sid: request.sid,
      browserPub: request.browserPub,
    );
    await _remote.approveQr(sid: request.sid, approval: approval);
  }

  @override
  Future<void> reject(QrLoginRequest request) => _remote.rejectQr(request.sid);

  /// Client-supplied text is untrusted: keep it short and on one line.
  static String _text(Object? value) {
    if (value is! String) {
      return '';
    }
    final clean = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return clean.length > 200 ? '${clean.substring(0, 200)}…' : clean;
  }
}
