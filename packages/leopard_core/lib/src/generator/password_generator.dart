import 'dart:math' as math;

import '../crypto/secure_random.dart';

/// Character classes a generated password can draw from.
enum CharClass {
  lowercase('abcdefghijklmnopqrstuvwxyz'),
  uppercase('ABCDEFGHIJKLMNOPQRSTUVWXYZ'),
  digits('0123456789'),
  symbols(r'!@#$%^&*()-_=+[]{};:,.?/|~');

  const CharClass(this.characters);

  /// Every character of the class, before any exclusion.
  final String characters;
}

/// Characters that are easy to confuse when read or typed: zero and the
/// letter O, one and the letters l and I, and the vertical bar.
const String ambiguousCharacters = '0Oo1lI|';

/// Options for [generatePassword].
final class PasswordOptions {
  /// Defaults: 20 characters from all four classes, at least one of each.
  const PasswordOptions({
    this.length = 20,
    this.classes = const {
      CharClass.lowercase,
      CharClass.uppercase,
      CharClass.digits,
      CharClass.symbols,
    },
    this.excludeAmbiguous = false,
    this.requireEachClass = true,
  });

  /// Smallest and largest accepted [length].
  static const int minLength = 4;
  static const int maxLength = 128;

  /// Number of characters.
  final int length;

  /// The classes to draw from. Must not be empty.
  final Set<CharClass> classes;

  /// Leave out [ambiguousCharacters].
  final bool excludeAmbiguous;

  /// Guarantee at least one character from every class in [classes].
  final bool requireEachClass;

  /// The characters of [charClass] that these options allow.
  String charactersOf(CharClass charClass) {
    if (!excludeAmbiguous) {
      return charClass.characters;
    }
    final out = StringBuffer();
    for (var i = 0; i < charClass.characters.length; i++) {
      final c = charClass.characters[i];
      if (!ambiguousCharacters.contains(c)) {
        out.write(c);
      }
    }
    return out.toString();
  }

  /// All allowed characters, in a fixed order.
  String get alphabet => [
    for (final c in CharClass.values)
      if (classes.contains(c)) charactersOf(c),
  ].join();

  /// Throws [ArgumentError] if the options cannot be satisfied.
  void validate() {
    if (classes.isEmpty) {
      throw ArgumentError.value(classes, 'classes', 'must not be empty');
    }
    if (length < minLength || length > maxLength) {
      throw ArgumentError.value(
        length,
        'length',
        'must be between $minLength and $maxLength',
      );
    }
    if (requireEachClass && length < classes.length) {
      throw ArgumentError.value(
        length,
        'length',
        'too short to contain one character of each class',
      );
    }
  }

  /// The exact entropy, in bits, of a password generated with these
  /// options: log2 of the number of passwords the generator can produce,
  /// every one of which is equally likely.
  ///
  /// Without [requireEachClass] that is `length * log2(alphabet size)`. With
  /// it, the passwords missing a class are excluded (counted by
  /// inclusion-exclusion), which costs a fraction of a bit at typical
  /// lengths.
  double get entropyBits {
    validate();
    final sizes = [
      for (final c in CharClass.values)
        if (classes.contains(c)) charactersOf(c).length,
    ];
    final total = sizes.fold<int>(0, (a, b) => a + b);
    if (!requireEachClass) {
      return length * _log2(total.toDouble());
    }
    // Count = sum over subsets S of classes of (-1)^|S| * (N - |S chars|)^L.
    // Scaled by N^L so every term is in [0, 1].
    var fraction = 0.0;
    for (var mask = 0; mask < (1 << sizes.length); mask++) {
      var removed = 0;
      var bits = 0;
      for (var i = 0; i < sizes.length; i++) {
        if (mask & (1 << i) != 0) {
          removed += sizes[i];
          bits++;
        }
      }
      final term = math.pow((total - removed) / total, length).toDouble();
      fraction += bits.isEven ? term : -term;
    }
    return length * _log2(total.toDouble()) + _log2(fraction);
  }
}

/// Generates a random password.
///
/// Every character is drawn uniformly from the allowed alphabet with
/// rejection sampling over `Random.secure()` (no modulo bias). With
/// [PasswordOptions.requireEachClass], whole candidates that miss a class
/// are discarded and redrawn, so the result is uniform over all passwords
/// that satisfy the options; no position is special.
///
/// The result is a Dart string and cannot be wiped from memory.
String generatePassword([PasswordOptions options = const PasswordOptions()]) {
  options.validate();
  final alphabet = options.alphabet;
  final required = options.requireEachClass
      ? [for (final c in options.classes) options.charactersOf(c)]
      : const <String>[];
  while (true) {
    final out = StringBuffer();
    for (var i = 0; i < options.length; i++) {
      out.write(alphabet[uniformInt(alphabet.length)]);
    }
    final candidate = out.toString();
    if (required.every((chars) => _containsAny(candidate, chars))) {
      return candidate;
    }
  }
}

bool _containsAny(String text, String characters) {
  for (var i = 0; i < text.length; i++) {
    if (characters.contains(text[i])) {
      return true;
    }
  }
  return false;
}

double _log2(double x) => math.log(x) / math.ln2;
