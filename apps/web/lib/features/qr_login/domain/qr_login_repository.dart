import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

/// One QR login request of this browser (crypto-spec §10.1, steps 1 to 3).
///
/// Holds the ephemeral X25519 private key and the poll token. Both exist in
/// memory only and neither is part of the QR code. [destroy] zeroes the
/// private key; the repository calls it as soon as the attempt is over.
final class QrLoginAttempt {
  QrLoginAttempt({
    required this.sid,
    required this.pollToken,
    required this.keyPair,
    required this.qrText,
    required this.verifyCode,
    required this.expiresAt,
  });

  /// 16-byte session id.
  final Uint8List sid;

  /// Needed to collect the result. Secret.
  final String pollToken;

  /// The browser's ephemeral key pair.
  final X25519KeyPair keyPair;

  /// The exact text to render as the QR code:
  /// `leopard://qr?v=1&sid=…&pk=…`.
  final String qrText;

  /// The 6-digit code, computed in this browser.
  final String verifyCode;

  /// When the server stops accepting an approval.
  final DateTime expiresAt;

  bool _destroyed = false;

  bool get isDestroyed => _destroyed;

  void destroy() {
    _destroyed = true;
    keyPair.destroy();
  }
}

/// What one poll of `GET /v1/qr/{sid}` means for the login page.
enum QrPollOutcome {
  /// Nobody has approved or rejected yet.
  pending,

  /// The phone approved, the vault key was decrypted and the session is
  /// open.
  signedIn,

  /// The phone rejected the request.
  rejected,

  /// The request timed out (60 s), or the server no longer knows it.
  expired,

  /// The approval was already collected; this attempt can never succeed.
  consumed,
}

abstract interface class QrLoginRepository {
  /// Generates the ephemeral key pair and registers a request with
  /// `POST /v1/qr`.
  ///
  /// Throws `ServerMismatchFailure` if the server's verification code or QR
  /// text differ from the values computed here.
  Future<QrLoginAttempt> begin();

  /// Polls once. On approval decrypts the vault key (crypto-spec §10.1 step
  /// 9), opens the session and destroys the attempt's private key.
  ///
  /// Throws `ServerMismatchFailure` if the approval does not decrypt; the
  /// session the server handed out is revoked again.
  Future<QrPollOutcome> poll(QrLoginAttempt attempt);

  /// Gives up on [attempt] and zeroes its private key.
  void abandon(QrLoginAttempt attempt);
}
