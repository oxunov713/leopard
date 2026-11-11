import 'dart:math';
import 'dart:typed_data';

/// The only source of randomness in this package: the platform CSPRNG.
final Random _secure = Random.secure();

/// Returns [length] bytes from the operating system CSPRNG
/// (`Random.secure()`).
Uint8List randomBytes(int length) {
  if (length < 0) {
    throw RangeError.range(length, 0, null, 'length');
  }
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secure.nextInt(256);
  }
  return out;
}

/// Largest bound accepted by [uniformInt]. Kept below 2^31 so that the bit
/// arithmetic is exact on JavaScript as well.
const int maxUniformBound = 1 << 30;

/// Returns a uniformly distributed integer in `[0, upperExclusive)` from the
/// CSPRNG, using rejection sampling (no modulo bias).
int uniformInt(int upperExclusive) =>
    uniformIntFromBytes(upperExclusive, () => _secure.nextInt(256));

/// Rejection sampling over an arbitrary byte source. Exposed so the sampling
/// logic can be tested with a deterministic source; production code calls
/// [uniformInt].
///
/// Draws the smallest whole number of bytes that covers `upperExclusive - 1`,
/// masks the value down to the smallest power of two that is at least
/// `upperExclusive`, and retries while the value is out of range. Each
/// accepted value is therefore equally likely, and at most half the draws
/// are rejected.
int uniformIntFromBytes(int upperExclusive, int Function() nextByte) {
  if (upperExclusive < 1 || upperExclusive > maxUniformBound) {
    throw RangeError.range(
      upperExclusive,
      1,
      maxUniformBound,
      'upperExclusive',
    );
  }
  if (upperExclusive == 1) {
    return 0;
  }
  final bits = (upperExclusive - 1).bitLength;
  final byteCount = (bits + 7) >> 3;
  final mask = (1 << bits) - 1;
  while (true) {
    var value = 0;
    for (var i = 0; i < byteCount; i++) {
      value = (value << 8) | (nextByte() & 0xff);
    }
    value &= mask;
    if (value < upperExclusive) {
      return value;
    }
  }
}
