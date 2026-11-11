import 'dart:math' as math;

import '../crypto/secure_random.dart';
import 'eff_short_wordlist.dart';

/// Options for [generatePassphrase].
final class PassphraseOptions {
  /// Defaults: six lower-case words joined by `-` (about 62 bits).
  const PassphraseOptions({
    this.wordCount = 6,
    this.separator = '-',
    this.capitalize = false,
    this.includeNumber = false,
  });

  /// Smallest and largest accepted [wordCount].
  static const int minWords = 3;
  static const int maxWords = 20;

  /// Number of words. Six or more is recommended for anything important.
  final int wordCount;

  /// Text between words. Adds no entropy.
  final String separator;

  /// Upper-case the first letter of every word. Adds no entropy.
  final bool capitalize;

  /// Append one random digit to one randomly chosen word.
  final bool includeNumber;

  /// Throws [ArgumentError] if the options are out of range.
  void validate() {
    if (wordCount < minWords || wordCount > maxWords) {
      throw ArgumentError.value(
        wordCount,
        'wordCount',
        'must be between $minWords and $maxWords',
      );
    }
  }

  /// Entropy in bits of a passphrase generated with these options:
  /// `wordCount * log2(1296)`, plus `log2(10 * wordCount)` for the digit
  /// and its position when [includeNumber] is set.
  double get entropyBits {
    validate();
    var bits = wordCount * _log2(effShortWordlist.length.toDouble());
    if (includeNumber) {
      bits += _log2(10.0 * wordCount);
    }
    return bits;
  }
}

/// Generates a passphrase from the EFF Short Wordlist 1 (1296 words, 10.34
/// bits per word). Words are chosen independently and uniformly with
/// rejection sampling over `Random.secure()`; repeats are allowed, as the
/// entropy figure assumes.
///
/// One word of the list, `yo-yo`, contains a hyphen. That does not reduce
/// entropy; it only means a passphrase cannot always be split back into
/// words on the default separator.
String generatePassphrase([
  PassphraseOptions options = const PassphraseOptions(),
]) {
  options.validate();
  final words = <String>[
    for (var i = 0; i < options.wordCount; i++)
      effShortWordlist[uniformInt(effShortWordlist.length)],
  ];
  if (options.capitalize) {
    for (var i = 0; i < words.length; i++) {
      words[i] = words[i][0].toUpperCase() + words[i].substring(1);
    }
  }
  if (options.includeNumber) {
    final position = uniformInt(words.length);
    words[position] = '${words[position]}${uniformInt(10)}';
  }
  return words.join(options.separator);
}

double _log2(double x) => math.log(x) / math.ln2;
