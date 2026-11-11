import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../../core/error/failures.dart';

/// A browser login waiting for approval, as shown to the user.
final class QrLoginRequest extends Equatable {
  const QrLoginRequest({
    required this.sid,
    required this.browserPub,
    required this.verifyCode,
    required this.ip,
    required this.browser,
    required this.platform,
    required this.userAgent,
    required this.createdAt,
    required this.expiresAt,
  });

  /// Both taken from the scanned QR code, never from the server.
  final Uint8List sid;
  final Uint8List browserPub;

  /// Six digits computed on the phone from [sid] and [browserPub]; the
  /// browser shows the same code if nobody is in the middle.
  final String verifyCode;

  /// Where the request came from, as seen by the server.
  final String ip;

  /// What the browser says about itself. Untrusted, display only.
  final String browser;
  final String platform;
  final String userAgent;
  final DateTime createdAt;
  final DateTime expiresAt;

  @override
  List<Object?> get props => [
    sid,
    browserPub,
    verifyCode,
    ip,
    browser,
    platform,
    userAgent,
    createdAt,
    expiresAt,
  ];
}

/// The scanned code or the server's answer must not be trusted.
final class QrRejectedFailure extends AppFailure {
  const QrRejectedFailure(super.message);
}

abstract interface class QrLoginRepository {
  /// Parses the scanned text and fetches the request's details.
  ///
  /// Throws [QrRejectedFailure] when the code is not a Leopard login code,
  /// when the server reports a different browser key or verification code
  /// than the QR code implies, or when the request is no longer pending.
  Future<QrLoginRequest> load(String scannedText);

  /// Asks for the biometric. Returns `true` when the user passed.
  Future<bool> confirmPresence();

  /// Encrypts the vault key to the browser and signs the approval.
  Future<void> approve(QrLoginRequest request);

  Future<void> reject(QrLoginRequest request);
}
