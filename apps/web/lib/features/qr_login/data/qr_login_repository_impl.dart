import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../../../core/network/leopard_api.dart';
import '../../../core/session/vault_session.dart';
import '../domain/qr_login_repository.dart';

/// [QrLoginRepository] on the API and `leopard_core`'s crypto.
final class QrLoginRepositoryImpl implements QrLoginRepository {
  QrLoginRepositoryImpl({
    required LeopardApi api,
    required VaultSession session,
    required LeopardCrypto crypto,
    Map<String, Object?> Function()? clientInfo,
  }) : _api = api,
       _session = session,
       _crypto = crypto,
       _clientInfo = clientInfo;

  final LeopardApi _api;
  final VaultSession _session;
  final LeopardCrypto _crypto;
  final Map<String, Object?> Function()? _clientInfo;

  @override
  Future<QrLoginAttempt> begin() async {
    final keyPair = await _crypto.generateX25519KeyPair();
    try {
      final created = await _api.createQrSession(
        browserPub: keyPair.publicKey,
        clientInfo: _clientInfo?.call(),
      );
      // Both values are recomputed here from the sid and this browser's own
      // key (crypto-spec §10.3). What is shown is the local result; a server
      // that disagrees is not trusted with a login.
      final qrText = QrUri(
        sid: created.sid,
        browserPub: keyPair.publicKey,
      ).toString();
      final code = await _crypto.verifyCode(
        sid: created.sid,
        browserPub: keyPair.publicKey,
      );
      if (created.qrUri != qrText || created.verifyCode != code) {
        throw const ServerMismatchFailure(
          'The server answered with a different code than this browser '
          'computed. The login was stopped.',
        );
      }
      return QrLoginAttempt(
        sid: created.sid,
        pollToken: created.pollToken,
        keyPair: keyPair,
        qrText: qrText,
        verifyCode: code,
        expiresAt: created.expiresAt,
      );
    } on Object {
      keyPair.destroy();
      rethrow;
    }
  }

  @override
  Future<QrPollOutcome> poll(QrLoginAttempt attempt) async {
    if (attempt.isDestroyed) {
      return QrPollOutcome.expired;
    }
    final QrPollResult result;
    try {
      result = await _api.pollQrSession(
        sid: attempt.sid,
        pollToken: attempt.pollToken,
      );
    } on NotFoundException {
      // qr_not_found: the server dropped the request.
      attempt.destroy();
      return QrPollOutcome.expired;
    }
    switch (result) {
      case QrPollWaiting(:final status):
        switch (status) {
          case QrStatus.pending:
            return QrPollOutcome.pending;
          case QrStatus.rejected:
            attempt.destroy();
            return QrPollOutcome.rejected;
          case QrStatus.expired:
            attempt.destroy();
            return QrPollOutcome.expired;
          case QrStatus.consumed || QrStatus.approved:
            attempt.destroy();
            return QrPollOutcome.consumed;
        }
      case QrPollApproved():
        await _open(attempt, result);
        return QrPollOutcome.signedIn;
    }
  }

  Future<void> _open(QrLoginAttempt attempt, QrPollApproved approved) async {
    Uint8List? vaultKey;
    try {
      vaultKey = await _crypto.qrOpenVaultKey(
        browserPrivateKey: attempt.keyPair.privateKey,
        phoneEphPub: approved.phoneEphPub,
        sid: attempt.sid,
        nonce: approved.nonce,
        ciphertext: approved.ciphertext,
      );
      final itemKey = await _crypto.deriveItemKey(vaultKey);
      _session.open(
        UnlockedVault(
          vaultKey: vaultKey,
          itemKey: itemKey,
          sessionId: approved.session.sessionId,
          method: LoginMethod.qr,
          idleTimeout: Duration(seconds: approved.session.idleTimeoutSeconds),
        ),
      );
    } on LeopardCryptoException {
      wipe(vaultKey);
      // The payload was not made for this browser key and this sid. The
      // token that came with it is of no use without the vault key.
      await _discardSession();
      throw const ServerMismatchFailure(
        'The approval could not be decrypted in this browser. Nothing was '
        'unlocked; show a new code and try again.',
      );
    } finally {
      // b_priv is discarded whether or not the vault key came out.
      attempt.destroy();
    }
  }

  Future<void> _discardSession() async {
    try {
      await _api.logout();
    } on Object {
      _api.clearSession();
    }
  }

  @override
  void abandon(QrLoginAttempt attempt) => attempt.destroy();
}
