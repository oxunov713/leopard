import 'dart:math' as math;

/// Why a password was scored down by [estimatePasswordStrength].
enum PasswordPattern {
  /// The password, ignoring case, is on the built-in list of very common
  /// passwords.
  common,

  /// The whole password is one short block repeated (`abcabcabc`), or it
  /// has a run of one repeated character (`aaaa`).
  repeated,

  /// A run of consecutive characters: alphabetic or numeric (`abcd`,
  /// `4321`) or along a keyboard row (`qwerty`).
  sequence,
}

/// Result of [estimatePasswordStrength].
final class PasswordStrength {
  const PasswordStrength({required this.bits, required this.patterns});

  /// Estimated entropy in bits.
  final double bits;

  /// The weak patterns that were found.
  final Set<PasswordPattern> patterns;

  @override
  String toString() => 'PasswordStrength(${bits.toStringAsFixed(1)} bits)';
}

/// A short list of very common passwords. Deliberately small: it catches the
/// worst offenders offline. It is not a breach database.
const Set<String> commonPasswords = {
  '123456',
  '1234567',
  '12345678',
  '123456789',
  '1234567890',
  '12345',
  '1234',
  '111111',
  '000000',
  '123123',
  '654321',
  '666666',
  '121212',
  '112233',
  '123321',
  '987654321',
  'password',
  'password1',
  'password123',
  'passw0rd',
  'p@ssw0rd',
  'p@ssword',
  'qwerty',
  'qwerty123',
  'qwertyuiop',
  'qwerty1',
  'azerty',
  'asdfgh',
  'asdfghjkl',
  'zxcvbn',
  'zxcvbnm',
  '1q2w3e',
  '1q2w3e4r',
  '1q2w3e4r5t',
  'qazwsx',
  '1qaz2wsx',
  'abc123',
  'abcd1234',
  'a1b2c3',
  'iloveyou',
  'admin',
  'admin123',
  'administrator',
  'root',
  'toor',
  'letmein',
  'welcome',
  'welcome1',
  'monkey',
  'dragon',
  'football',
  'baseball',
  'superman',
  'batman',
  'master',
  'shadow',
  'sunshine',
  'princess',
  'login',
  'guest',
  'default',
  'changeme',
  'secret',
  'test',
  'test123',
  'qwe123',
  'trustno1',
  'starwars',
  'hello',
  'hello123',
  'freedom',
  'whatever',
  'michael',
  'jordan',
  'killer',
  'pokemon',
  'google',
  'computer',
  'internet',
  'samsung',
  'iphone',
  'liverpool',
  'chelsea',
  'arsenal',
  'barcelona',
  'ronaldo',
  'messi',
  'qwertyui',
  'asdf1234',
  'zaq12wsx',
  '1qazxsw2',
  'q1w2e3r4',
  'aa123456',
  '147258369',
  '159753',
  '7777777',
  '88888888',
  '11111111',
  '00000000',
  'correct horse battery staple',
};

const List<String> _keyboardRows = [
  'qwertyuiop',
  'asdfghjkl',
  'zxcvbnm',
  '1234567890',
];

/// Estimates the strength of a password a human may have chosen, in bits.
///
/// This is a deliberately simple heuristic, not a cracker model:
///
/// * the alphabet is inferred from the classes of characters present
///   (26 lower, 26 upper, 10 digits, 33 symbols, 100 for anything else);
/// * each character normally contributes `log2(alphabet)` bits;
/// * a character that merely continues a run (same character, next or
///   previous code point, or next key on a keyboard row) contributes 1 bit;
/// * a password that is one block repeated is scored as the block plus
///   `log2(repetitions)`;
/// * a password on the [commonPasswords] list scores at most
///   `log2(list size)`.
///
/// For randomly generated passwords the result equals the true entropy up
/// to the occasional accidental run; for human passwords it is an
/// optimistic upper bound. Use it to flag weak passwords, not to certify
/// strong ones.
PasswordStrength estimatePasswordStrength(String password) {
  if (password.isEmpty) {
    return const PasswordStrength(bits: 0, patterns: {});
  }
  final patterns = <PasswordPattern>{};
  final units = password.runes.toList();
  final perChar = _log2(_alphabetSize(units).toDouble());

  var bits = _runAwareBits(units, perChar, patterns);

  final block = _repeatedBlockLength(units);
  if (block != null) {
    patterns.add(PasswordPattern.repeated);
    final blockBits = _runAwareBits(units.sublist(0, block), perChar, {});
    bits = math.min(bits, blockBits + _log2(units.length / block));
  }

  if (commonPasswords.contains(password.toLowerCase())) {
    patterns.add(PasswordPattern.common);
    bits = math.min(bits, _log2(commonPasswords.length.toDouble()));
  }
  return PasswordStrength(bits: bits, patterns: patterns);
}

int _alphabetSize(List<int> units) {
  var lower = false;
  var upper = false;
  var digit = false;
  var symbol = false;
  var other = false;
  for (final c in units) {
    if (c >= 0x61 && c <= 0x7a) {
      lower = true;
    } else if (c >= 0x41 && c <= 0x5a) {
      upper = true;
    } else if (c >= 0x30 && c <= 0x39) {
      digit = true;
    } else if (c >= 0x20 && c <= 0x7e) {
      symbol = true;
    } else {
      other = true;
    }
  }
  return (lower ? 26 : 0) +
      (upper ? 26 : 0) +
      (digit ? 10 : 0) +
      (symbol ? 33 : 0) +
      (other ? 100 : 0);
}

/// Sums per-character bits, charging 1 bit for a character that continues
/// a run of at least three. Records the kind of run in [patterns].
double _runAwareBits(
  List<int> units,
  double perChar,
  Set<PasswordPattern> patterns,
) {
  var bits = 0.0;
  // Bit mask of the ways the previous pair of characters was "in step".
  var previous = 0;
  for (var i = 0; i < units.length; i++) {
    final steps = i == 0 ? 0 : _steps(units[i - 1], units[i]);
    final continued = steps & previous;
    if (continued != 0) {
      // Third or later character of a run.
      bits += 1;
      patterns.add(
        continued & _stepSame != 0
            ? PasswordPattern.repeated
            : PasswordPattern.sequence,
      );
      previous = continued;
    } else {
      bits += perChar;
      previous = steps;
    }
  }
  return bits;
}

const int _stepSame = 1;
const int _stepAscending = 2;
const int _stepDescending = 4;
const int _stepKeyboardForward = 8;
const int _stepKeyboardBackward = 16;

/// Every way in which [b] follows [a] as part of a run, as a bit mask. A
/// pair can be in step in two ways at once (`o`, `p` is both alphabetical
/// and adjacent on the keyboard).
int _steps(int a, int b) {
  if (a == b) return _stepSame;
  var mask = 0;
  if (_isAlphanumeric(a) && _isAlphanumeric(b)) {
    if (b == a + 1) mask |= _stepAscending;
    if (b == a - 1) mask |= _stepDescending;
  }
  final la = String.fromCharCode(_lower(a));
  final lb = String.fromCharCode(_lower(b));
  for (final row in _keyboardRows) {
    final ia = row.indexOf(la);
    if (ia < 0) continue;
    final ib = row.indexOf(lb);
    if (ib < 0) continue;
    if (ib == ia + 1) mask |= _stepKeyboardForward;
    if (ib == ia - 1) mask |= _stepKeyboardBackward;
  }
  return mask;
}

bool _isAlphanumeric(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a);

int _lower(int c) => (c >= 0x41 && c <= 0x5a) ? c + 0x20 : c;

/// If [units] is one block of length `n` repeated two or more times,
/// returns the smallest such `n` (1 for `aaaa`, 3 for `abcabc`).
int? _repeatedBlockLength(List<int> units) {
  final length = units.length;
  for (var n = 1; n <= length ~/ 2; n++) {
    if (length % n != 0) continue;
    var repeats = true;
    for (var i = n; i < length && repeats; i++) {
      repeats = units[i] == units[i - n];
    }
    if (repeats) return n;
  }
  return null;
}

double _log2(double x) => math.log(x) / math.ln2;
