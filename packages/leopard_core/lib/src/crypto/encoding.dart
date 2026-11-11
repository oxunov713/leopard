import 'dart:typed_data';

import 'bytes.dart';
import 'constants.dart';
import 'errors.dart';
import 'secure_random.dart';

const String _b64Alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
const String _b32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const String _hexDigits = '0123456789abcdef';

final List<int> _b64Reverse = _reverseTable(_b64Alphabet);
final List<int> _b32Reverse = _reverseTable(_b32Alphabet);

List<int> _reverseTable(String alphabet) {
  final table = List<int>.filled(128, -1);
  for (var i = 0; i < alphabet.length; i++) {
    table[alphabet.codeUnitAt(i)] = i;
  }
  return table;
}

/// Encodes [bytes] for the wire: base64url (RFC 4648 §5) **without** `=`
/// padding.
String base64UrlEncodeNoPad(List<int> bytes) {
  final out = StringBuffer();
  var i = 0;
  for (; i + 3 <= bytes.length; i += 3) {
    final n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out
      ..write(_b64Alphabet[(n >> 18) & 63])
      ..write(_b64Alphabet[(n >> 12) & 63])
      ..write(_b64Alphabet[(n >> 6) & 63])
      ..write(_b64Alphabet[n & 63]);
  }
  final rest = bytes.length - i;
  if (rest == 1) {
    final n = bytes[i] << 16;
    out
      ..write(_b64Alphabet[(n >> 18) & 63])
      ..write(_b64Alphabet[(n >> 12) & 63]);
  } else if (rest == 2) {
    final n = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out
      ..write(_b64Alphabet[(n >> 18) & 63])
      ..write(_b64Alphabet[(n >> 12) & 63])
      ..write(_b64Alphabet[(n >> 6) & 63]);
  }
  return out.toString();
}

/// Decodes strict base64url without padding.
///
/// Throws [InvalidFormatException] on `=` padding, on any character outside
/// the URL-safe alphabet (including `+`, `/` and whitespace), on an
/// impossible length and on non-zero trailing bits.
Uint8List base64UrlDecodeNoPad(String text) {
  final length = text.length;
  final rest = length % 4;
  if (rest == 1) {
    throw const InvalidFormatException('invalid base64url length');
  }
  final out = Uint8List((length ~/ 4) * 3 + (rest == 0 ? 0 : rest - 1));
  var acc = 0;
  var accBits = 0;
  var o = 0;
  for (var i = 0; i < length; i++) {
    final c = text.codeUnitAt(i);
    final v = c < 128 ? _b64Reverse[c] : -1;
    if (v < 0) {
      throw const InvalidFormatException('invalid base64url character');
    }
    acc = ((acc << 6) | v) & 0xffff;
    accBits += 6;
    if (accBits >= 8) {
      accBits -= 8;
      out[o++] = (acc >> accBits) & 0xff;
    }
  }
  if ((acc & ((1 << accBits) - 1)) != 0) {
    throw const InvalidFormatException('non-zero trailing bits in base64url');
  }
  return out;
}

/// Decodes strict base64url and requires exactly [size] bytes.
Uint8List base64UrlDecodeSized(String text, int size, String name) {
  final Uint8List bytes;
  try {
    bytes = base64UrlDecodeNoPad(text);
  } on InvalidFormatException {
    throw InvalidFormatException('$name is not valid base64url');
  }
  if (bytes.length != size) {
    throw InvalidSizeException(
      '$name must be $size bytes, got ${bytes.length}',
    );
  }
  return bytes;
}

/// Encodes [bytes] as Base32 (RFC 4648 §6, alphabet `A-Z 2-7`) without
/// padding.
String base32EncodeNoPad(List<int> bytes) {
  final out = StringBuffer();
  var acc = 0;
  var accBits = 0;
  for (final b in bytes) {
    acc = ((acc << 8) | (b & 0xff)) & 0xfff;
    accBits += 8;
    while (accBits >= 5) {
      accBits -= 5;
      out.write(_b32Alphabet[(acc >> accBits) & 31]);
    }
  }
  if (accBits > 0) {
    out.write(_b32Alphabet[(acc << (5 - accBits)) & 31]);
  }
  return out.toString();
}

/// Decodes unpadded upper-case Base32. Surplus trailing bits are dropped;
/// callers that need canonical input must re-encode and compare (see
/// `parseRecoveryKey`).
///
/// Throws [InvalidFormatException] on any character outside `A-Z 2-7`.
Uint8List base32DecodeNoPad(String text) {
  final out = Uint8List((text.length * 5) ~/ 8);
  var acc = 0;
  var accBits = 0;
  var o = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    final v = c < 128 ? _b32Reverse[c] : -1;
    if (v < 0) {
      throw const InvalidFormatException('invalid Base32 character');
    }
    acc = ((acc << 5) | v) & 0xfff;
    accBits += 5;
    if (accBits >= 8) {
      accBits -= 8;
      out[o++] = (acc >> accBits) & 0xff;
    }
  }
  return out;
}

/// Lower-case hex, used for diagnostics and test vectors (not a wire
/// format).
String hexEncode(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out
      ..write(_hexDigits[(b >> 4) & 15])
      ..write(_hexDigits[b & 15]);
  }
  return out.toString();
}

/// Decodes hex of either case. Throws [InvalidFormatException] on bad input.
Uint8List hexDecode(String text) {
  if (text.length.isOdd) {
    throw const InvalidFormatException('hex string has odd length');
  }
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _hexValue(text.codeUnitAt(2 * i));
    final lo = _hexValue(text.codeUnitAt(2 * i + 1));
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  throw const InvalidFormatException('invalid hex character');
}

/// Whether [s] is a canonical UUID: `8-4-4-4-12`, lower-case hex. Upper-case
/// is rejected, exactly as the server does.
bool isCanonicalUuid(String s) {
  if (s.length != uuidLength) {
    return false;
  }
  for (var i = 0; i < uuidLength; i++) {
    final c = s.codeUnitAt(i);
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (c != 0x2d) return false;
    } else {
      final isDigit = c >= 0x30 && c <= 0x39;
      final isLowerHex = c >= 0x61 && c <= 0x66;
      if (!isDigit && !isLowerHex) return false;
    }
  }
  return true;
}

/// Returns a random (version 4) UUID in canonical lower-case form.
String newUuid() {
  final b = randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = hexEncode(b);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// The 36 ASCII bytes of a canonical UUID, as used inside cryptographic
/// computations. Throws [InvalidFormatException] if [uuid] is not canonical.
Uint8List uuidAsciiBytes(String uuid, String name) {
  if (!isCanonicalUuid(uuid)) {
    throw InvalidFormatException('$name is not a canonical lower-case UUID');
  }
  return asciiBytes(uuid);
}
