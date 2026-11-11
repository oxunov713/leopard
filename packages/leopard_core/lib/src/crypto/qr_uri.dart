import 'dart:typed_data';

import 'bytes.dart';
import 'constants.dart';
import 'encoding.dart';
import 'errors.dart';

const String _qrPrefix = 'leopard://qr?';

/// The contents of a login QR code (crypto-spec §10.1 step 3):
/// `leopard://qr?v=1&sid=<base64url sid>&pk=<base64url browser_pub>`.
final class QrUri {
  /// Creates the QR payload for a session. Throws [InvalidSizeException] if
  /// a field has the wrong length.
  QrUri({required Uint8List sid, required Uint8List browserPub})
    : sid = Uint8List.fromList(sid),
      browserPub = Uint8List.fromList(browserPub) {
    checkSize(sid, sidSize, 'sid');
    checkSize(browserPub, x25519KeySize, 'browser_pub');
  }

  /// Parses the text scanned from a QR code.
  ///
  /// Parsing is strict: the scheme and host must be exactly `leopard://qr`,
  /// there must be exactly the three parameters `v`, `sid` and `pk` (in any
  /// order, each once, no percent-encoding), `v` must be `1`, and both
  /// binary fields must be strict base64url of the right size.
  ///
  /// Throws [InvalidFormatException] for anything else.
  factory QrUri.parse(String text) {
    if (!text.startsWith(_qrPrefix)) {
      throw const InvalidFormatException('not a Leopard QR code');
    }
    final params = <String, String>{};
    for (final pair in text.substring(_qrPrefix.length).split('&')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) {
        throw const InvalidFormatException('malformed QR code');
      }
      final key = pair.substring(0, eq);
      if (params.containsKey(key)) {
        throw const InvalidFormatException('malformed QR code');
      }
      params[key] = pair.substring(eq + 1);
    }
    if (params.length != 3 ||
        !params.containsKey('v') ||
        !params.containsKey('sid') ||
        !params.containsKey('pk')) {
      throw const InvalidFormatException('malformed QR code');
    }
    if (params['v'] != '1') {
      throw const InvalidFormatException('unsupported QR code version');
    }
    try {
      return QrUri(
        sid: base64UrlDecodeSized(params['sid']!, sidSize, 'sid'),
        browserPub: base64UrlDecodeSized(params['pk']!, x25519KeySize, 'pk'),
      );
    } on InvalidSizeException {
      throw const InvalidFormatException('malformed QR code');
    }
  }

  /// QR session id, 16 bytes.
  final Uint8List sid;

  /// The browser's ephemeral X25519 public key, 32 bytes.
  final Uint8List browserPub;

  /// `sid` in the wire encoding, as used in API paths.
  String get sidBase64 => base64UrlEncodeNoPad(sid);

  /// The exact text to render as a QR code.
  @override
  String toString() =>
      '${_qrPrefix}v=1&sid=${base64UrlEncodeNoPad(sid)}'
      '&pk=${base64UrlEncodeNoPad(browserPub)}';
}
