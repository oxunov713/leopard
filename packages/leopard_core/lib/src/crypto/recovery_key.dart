import 'dart:typed_data';

import 'bytes.dart';
import 'constants.dart';
import 'encoding.dart';
import 'errors.dart';

/// Number of Base32 characters in a recovery key (16 bytes, no padding).
const int recoveryKeyChars = 26;

/// Renders a 16-byte recovery key for display: 26 Base32 characters in
/// groups of four separated by `-`, the last group having two characters
/// (`XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX`, crypto-spec §8).
String formatRecoveryKey(Uint8List recoveryKey) {
  checkSize(recoveryKey, recoveryKeySize, 'recovery key');
  final s = base32EncodeNoPad(recoveryKey);
  final out = StringBuffer();
  for (var i = 0; i < s.length; i += 4) {
    if (i > 0) {
      out.write('-');
    }
    final end = i + 4 < s.length ? i + 4 : s.length;
    out.write(s.substring(i, end));
  }
  return out.toString();
}

/// Parses a recovery key as typed by the user.
///
/// `-` and ASCII whitespace (space, tab, CR, LF) are ignored and ASCII
/// letters are upper-cased. The result must be exactly 26 characters of the
/// Base32 alphabet and must re-encode to the same 26 characters: 26
/// characters carry 130 bits, and the two surplus bits must be zero.
///
/// Throws [InvalidFormatException] otherwise. The message never echoes the
/// input.
Uint8List parseRecoveryKey(String input) {
  final clean = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    final c = input.codeUnitAt(i);
    if (c == 0x2d || c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d) {
      continue;
    }
    if (c >= 0x61 && c <= 0x7a) {
      clean.writeCharCode(c - 0x20);
    } else {
      clean.writeCharCode(c);
    }
  }
  final text = clean.toString();
  if (text.length != recoveryKeyChars) {
    throw const InvalidFormatException(
      'recovery key must be 26 Base32 characters',
    );
  }
  final Uint8List bytes;
  try {
    bytes = base32DecodeNoPad(text);
  } on InvalidFormatException {
    throw const InvalidFormatException('malformed recovery key');
  }
  if (bytes.length != recoveryKeySize || base32EncodeNoPad(bytes) != text) {
    wipe(bytes);
    throw const InvalidFormatException('malformed recovery key');
  }
  return bytes;
}
