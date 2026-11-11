import 'dart:typed_data';

import 'errors.dart';

/// Concatenates [parts] into a new buffer.
Uint8List concatBytes(List<List<int>> parts) {
  var length = 0;
  for (final part in parts) {
    length += part.length;
  }
  final out = Uint8List(length);
  var offset = 0;
  for (final part in parts) {
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return out;
}

/// The bytes of an ASCII string literal (labels, UUIDs).
///
/// Throws [InvalidFormatException] if [s] contains a non-ASCII code unit.
Uint8List asciiBytes(String s) {
  final out = Uint8List(s.length);
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c > 0x7f) {
      throw const InvalidFormatException('expected an ASCII string');
    }
    out[i] = c;
  }
  return out;
}

/// Overwrites [buffer] with zeros.
///
/// **Best effort only.** Dart has a moving, generational garbage collector:
/// the VM may already have copied the bytes elsewhere, and the crypto
/// library makes internal copies this code cannot reach. Strings (passwords,
/// tokens, decoded JSON) are immutable and cannot be wiped at all. Wiping
/// shortens the lifetime of secrets in the common case; it is not a
/// guarantee. Do not hold secrets longer than needed.
void wipe(Uint8List? buffer) {
  buffer?.fillRange(0, buffer.length, 0);
}

/// [wipe]s every buffer in [buffers].
void wipeAll(Iterable<Uint8List?> buffers) {
  for (final buffer in buffers) {
    wipe(buffer);
  }
}

/// Compares two byte strings without an early exit on the first difference.
///
/// The lengths are not secret. Timing guarantees in Dart are weak (JIT,
/// GC); this avoids the obvious data-dependent branch and nothing more.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Whether every byte of [bytes] is zero, without an early exit.
bool isAllZero(List<int> bytes) {
  var acc = 0;
  for (final b in bytes) {
    acc |= b;
  }
  return acc == 0;
}

/// Throws [InvalidSizeException] unless [value] has exactly [expected] bytes.
void checkSize(List<int> value, int expected, String name) {
  if (value.length != expected) {
    throw InvalidSizeException(
      '$name must be $expected bytes, got ${value.length}',
    );
  }
}
