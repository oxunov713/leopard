import 'dart:math' as math;

import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_core/src/crypto/secure_random.dart';
import 'package:test/test.dart';

/// Pearson chi-square statistic of [counts] against a uniform expectation.
double chiSquare(List<int> counts) {
  final total = counts.fold<int>(0, (a, b) => a + b);
  final expected = total / counts.length;
  var sum = 0.0;
  for (final c in counts) {
    sum += (c - expected) * (c - expected) / expected;
  }
  return sum;
}

/// A generous upper bound for a chi-square statistic with [df] degrees of
/// freedom: mean + 8 standard deviations. For a correct sampler the chance
/// of exceeding it is far below one in a billion, so the tests do not flake;
/// a sampler with modulo bias exceeds it by orders of magnitude at the
/// sample sizes used here.
double chiSquareLimit(int df) => df + 8 * math.sqrt(2.0 * df);

void main() {
  group('uniformIntFromBytes (rejection sampling)', () {
    test('is exactly uniform over an exhaustive byte source', () {
      // Feed every byte value exactly once. A modulo-based sampler would
      // favour the low values (256 is not a multiple of these bounds); with
      // rejection sampling every accepted value appears equally often.
      for (final bound in [3, 5, 6, 7, 10, 26, 62, 77, 100, 200, 255]) {
        final counts = List<int>.filled(bound, 0);
        final bits = (bound - 1).bitLength;
        final copies = 256 >> bits;
        for (var b = 0; b < 256; b++) {
          var served = false;
          final value = uniformIntFromBytes(bound, () {
            if (!served) {
              served = true;
              return b;
            }
            // Second draw, after a rejection: zero is always in range.
            return 0;
          });
          final masked = b & ((1 << bits) - 1);
          if (masked < bound) {
            expect(value, masked);
            counts[value]++;
          } else {
            expect(value, 0, reason: 'rejected draw falls through');
          }
        }
        expect(counts, everyElement(copies), reason: 'bound $bound');
      }
    });

    test('rejects out-of-range values instead of reducing them', () {
      // bound 5 -> 3 bits. 5, 6 and 7 must be rejected, not mapped to 0..2.
      final source = [0x05, 0x06, 0x07, 0x04].iterator;
      final value = uniformIntFromBytes(5, () {
        source.moveNext();
        return source.current;
      });
      expect(value, 4);
    });

    test('uses multiple bytes for large bounds, big-endian', () {
      final source = [0x12, 0x34].iterator;
      final value = uniformIntFromBytes(1 << 16, () {
        source.moveNext();
        return source.current;
      });
      expect(value, 0x1234);
      // 1296 needs 11 bits: two bytes, masked to 0x7ff.
      final second = [0xff, 0xff, 0x05, 0x0f].iterator;
      expect(
        uniformIntFromBytes(1296, () {
          second.moveNext();
          return second.current;
        }),
        0x050f,
      );
    });

    test('bounds', () {
      expect(uniformIntFromBytes(1, () => fail('no draw needed')), 0);
      expect(() => uniformInt(0), throwsRangeError);
      expect(() => uniformInt(-1), throwsRangeError);
      expect(() => uniformInt(maxUniformBound + 1), throwsRangeError);
      expect(uniformInt(maxUniformBound), lessThan(maxUniformBound));
    });

    test('uniformInt over the CSPRNG shows no bias (chi-square)', () {
      // 77 is the worst case in spirit: far from a power of two.
      for (final bound in [3, 10, 77, 1296]) {
        final counts = List<int>.filled(bound, 0);
        final draws = bound * 400;
        for (var i = 0; i < draws; i++) {
          counts[uniformInt(bound)]++;
        }
        expect(
          chiSquare(counts),
          lessThan(chiSquareLimit(bound - 1)),
          reason: 'bound $bound',
        );
      }
    });

    test('randomBytes has the right length and is not constant', () {
      expect(randomBytes(0), isEmpty);
      expect(randomBytes(33), hasLength(33));
      expect(randomBytes(32), isNot(randomBytes(32)));
      expect(() => randomBytes(-1), throwsRangeError);
    });
  });

  group('password generator', () {
    test('default: 20 characters with every class', () {
      for (var i = 0; i < 200; i++) {
        final p = generatePassword();
        expect(p, hasLength(20));
        for (final c in CharClass.values) {
          expect(
            p.split('').any(c.characters.contains),
            isTrue,
            reason: '${c.name} missing',
          );
        }
      }
    });

    test('only selected classes appear, and each of them does', () {
      final subsets = <Set<CharClass>>[
        {CharClass.lowercase},
        {CharClass.digits},
        {CharClass.lowercase, CharClass.digits},
        {CharClass.uppercase, CharClass.symbols},
        {CharClass.lowercase, CharClass.uppercase, CharClass.digits},
      ];
      for (final classes in subsets) {
        final options = PasswordOptions(length: 12, classes: classes);
        final allowed = options.alphabet;
        for (var i = 0; i < 100; i++) {
          final p = generatePassword(options);
          expect(p, hasLength(12));
          expect(p.split('').every(allowed.contains), isTrue);
          for (final c in classes) {
            expect(p.split('').any(c.characters.contains), isTrue);
          }
        }
      }
    });

    test('every requested length is honoured', () {
      for (final length in [4, 5, 8, 16, 32, 64, 128]) {
        expect(
          generatePassword(PasswordOptions(length: length)),
          hasLength(length),
        );
      }
    });

    test('excludeAmbiguous removes exactly the ambiguous characters', () {
      const options = PasswordOptions(length: 64, excludeAmbiguous: true);
      expect(ambiguousCharacters, '0Oo1lI|');
      for (final c in ambiguousCharacters.split('')) {
        expect(options.alphabet.contains(c), isFalse);
      }
      expect(
        options.alphabet.length,
        const PasswordOptions().alphabet.length - ambiguousCharacters.length,
      );
      for (var i = 0; i < 200; i++) {
        final p = generatePassword(options);
        expect(p.split('').any(ambiguousCharacters.contains), isFalse);
      }
    });

    test('alphabets have no duplicates and classes do not overlap', () {
      final all = const PasswordOptions().alphabet;
      expect(all.split('').toSet(), hasLength(all.length));
      expect(all.length, 26 + 26 + 10 + CharClass.symbols.characters.length);
      expect(all.runes.every((r) => r > 0x20 && r < 0x7f), isTrue);
    });

    test('without requireEachClass a class may be absent', () {
      const options = PasswordOptions(
        length: 4,
        classes: {CharClass.lowercase, CharClass.digits},
        requireEachClass: false,
      );
      var sawLettersOnly = false;
      for (var i = 0; i < 500 && !sawLettersOnly; i++) {
        final p = generatePassword(options);
        sawLettersOnly = !p.split('').any(CharClass.digits.characters.contains);
      }
      // P(all letters) = (26/36)^4 = 27%, so 500 tries cannot all miss.
      expect(sawLettersOnly, isTrue);
    });

    test('characters are uniform over the alphabet (chi-square)', () {
      // requireEachClass off so that positions are independent draws.
      const options = PasswordOptions(length: 100, requireEachClass: false);
      final alphabet = options.alphabet;
      final counts = List<int>.filled(alphabet.length, 0);
      for (var i = 0; i < 400; i++) {
        for (final c in generatePassword(options).split('')) {
          counts[alphabet.indexOf(c)]++;
        }
      }
      expect(counts, everyElement(greaterThan(0)));
      expect(chiSquare(counts), lessThan(chiSquareLimit(alphabet.length - 1)));
    });

    test('no position is special when every class is required', () {
      // A "place one of each class first, then fill" generator would put
      // digits in fixed slots. Here each position should hold a digit about
      // 10/36 of the time.
      const options = PasswordOptions(
        length: 8,
        classes: {CharClass.lowercase, CharClass.digits},
      );
      const samples = 6000;
      final digitAt = List<int>.filled(8, 0);
      for (var i = 0; i < samples; i++) {
        final p = generatePassword(options);
        for (var k = 0; k < 8; k++) {
          if (CharClass.digits.characters.contains(p[k])) digitAt[k]++;
        }
      }
      for (final count in digitAt) {
        // Expected about 0.28 * 6000 = 1690; allow a very wide band.
        expect(count, inInclusiveRange(1400, 2000));
      }
    });

    test('successive passwords differ', () {
      final seen = {for (var i = 0; i < 500; i++) generatePassword()};
      expect(seen, hasLength(500));
    });

    test('invalid options are refused', () {
      expect(
        () => generatePassword(const PasswordOptions(classes: {})),
        throwsArgumentError,
      );
      expect(
        () => generatePassword(const PasswordOptions(length: 3)),
        throwsArgumentError,
      );
      expect(
        () => generatePassword(const PasswordOptions(length: 129)),
        throwsArgumentError,
      );
    });

    test('entropy of the options', () {
      const free = PasswordOptions(length: 20, requireEachClass: false);
      final perChar = math.log(free.alphabet.length) / math.ln2;
      expect(free.entropyBits, closeTo(20 * perChar, 1e-9));

      // Requiring each class removes a few candidates: slightly less.
      const strict = PasswordOptions(length: 20);
      expect(strict.entropyBits, lessThan(free.entropyBits));
      expect(strict.entropyBits, greaterThan(free.entropyBits - 1));

      // Exact check on a case small enough to count by hand: length 4 over
      // {a-z} and {0-9}: 36^4 - 26^4 - 10^4 = 1 212 640 passwords.
      const small = PasswordOptions(
        length: 4,
        classes: {CharClass.lowercase, CharClass.digits},
      );
      expect(small.entropyBits, closeTo(math.log(1212640) / math.ln2, 1e-9));

      const digits = PasswordOptions(length: 6, classes: {CharClass.digits});
      expect(digits.entropyBits, closeTo(6 * math.log(10) / math.ln2, 1e-9));
    });
  });

  group('wordlist', () {
    test('is the EFF short list: 1296 unique, sorted, short words', () {
      expect(effShortWordlist, hasLength(1296));
      expect(effShortWordlist.toSet(), hasLength(1296));
      expect(effShortWordlist.first, 'acid');
      expect(effShortWordlist.last, 'zoom');
      final sorted = [...effShortWordlist]..sort();
      expect(effShortWordlist, sorted);
      for (final word in effShortWordlist) {
        expect(word, matches(RegExp(r'^[a-z]+(-[a-z]+)?$')));
        expect(word.length, inInclusiveRange(3, 5));
      }
    });
  });

  group('passphrase generator', () {
    test('default: six lower-case words from the list', () {
      for (var i = 0; i < 100; i++) {
        final words = generatePassphrase(
          const PassphraseOptions(separator: ' '),
        ).split(' ');
        expect(words, hasLength(6));
        expect(words.every(effShortWordlist.contains), isTrue);
      }
      expect(generatePassphrase().split('-').length, greaterThanOrEqualTo(6));
    });

    test('word count, separator, capitals and number', () {
      final p = generatePassphrase(
        const PassphraseOptions(
          wordCount: 8,
          separator: '.',
          capitalize: true,
          includeNumber: true,
        ),
      );
      final words = p.split('.');
      expect(words, hasLength(8));
      var digits = 0;
      for (final word in words) {
        expect(word[0], word[0].toUpperCase());
        final bare = word.replaceAll(RegExp(r'\d$'), '');
        if (bare != word) digits++;
        expect(effShortWordlist.contains(bare.toLowerCase()), isTrue);
      }
      expect(digits, 1);
    });

    test('words are uniform over the list (chi-square)', () {
      final index = {
        for (var i = 0; i < effShortWordlist.length; i++)
          effShortWordlist[i]: i,
      };
      final counts = List<int>.filled(effShortWordlist.length, 0);
      const options = PassphraseOptions(wordCount: 20, separator: ' ');
      for (var i = 0; i < 13000; i++) {
        for (final word in generatePassphrase(options).split(' ')) {
          counts[index[word]!]++;
        }
      }
      expect(counts, everyElement(greaterThan(0)));
      expect(
        chiSquare(counts),
        lessThan(chiSquareLimit(effShortWordlist.length - 1)),
      );
    });

    test('entropy', () {
      final perWord = math.log(1296) / math.ln2;
      expect(const PassphraseOptions().entropyBits, closeTo(6 * perWord, 1e-9));
      expect(
        const PassphraseOptions(capitalize: true, separator: '').entropyBits,
        closeTo(6 * perWord, 1e-9),
      );
      expect(
        const PassphraseOptions(wordCount: 4, includeNumber: true).entropyBits,
        closeTo(4 * perWord + math.log(40) / math.ln2, 1e-9),
      );
    });

    test('invalid options are refused', () {
      expect(
        () => generatePassphrase(const PassphraseOptions(wordCount: 2)),
        throwsArgumentError,
      );
      expect(
        () => generatePassphrase(const PassphraseOptions(wordCount: 21)),
        throwsArgumentError,
      );
    });
  });

  group('strength estimate', () {
    double bits(String p) => estimatePasswordStrength(p).bits;
    Set<PasswordPattern> patterns(String p) =>
        estimatePasswordStrength(p).patterns;

    test('empty is zero', () {
      expect(bits(''), 0);
    });

    test('random passwords score close to their true entropy', () {
      const options = PasswordOptions(length: 20);
      for (var i = 0; i < 50; i++) {
        final estimate = bits(generatePassword(options));
        // Accidental runs can cost a little; never more than it has.
        expect(estimate, lessThan(20 * math.log(95) / math.ln2 + 1e-6));
        expect(estimate, greaterThan(100));
      }
    });

    test('alphabet inference', () {
      expect(bits('kxmqzv'), closeTo(6 * math.log(26) / math.ln2, 1e-9));
      expect(bits('kXmQzV'), closeTo(6 * math.log(52) / math.ln2, 1e-9));
      expect(bits('k7m2z9'), closeTo(6 * math.log(36) / math.ln2, 1e-9));
      expect(bits('k7M2z!'), closeTo(6 * math.log(95) / math.ln2, 1e-9));
      expect(bits('пароль'), closeTo(6 * math.log(100) / math.ln2, 1e-9));
    });

    test('common passwords are capped and flagged', () {
      for (final p in ['password', 'Password', 'QWERTY', '123456', 'letmein']) {
        expect(patterns(p), contains(PasswordPattern.common), reason: p);
        expect(bits(p), lessThan(8), reason: p);
      }
    });

    test('repeats and sequences are flagged and scored down', () {
      expect(patterns('aaaaaaaaaaaa'), contains(PasswordPattern.repeated));
      expect(bits('aaaaaaaaaaaa'), lessThan(10));
      expect(patterns('abcabcabcabc'), contains(PasswordPattern.repeated));
      expect(bits('abcabcabcabc'), lessThan(20));
      expect(patterns('abcdefghijkl'), contains(PasswordPattern.sequence));
      expect(bits('abcdefghijkl'), lessThan(25));
      expect(patterns('987654321098'), contains(PasswordPattern.sequence));
      expect(patterns('poiuytrewq12'), contains(PasswordPattern.sequence));
      expect(bits('qwertyuiopas'), lessThan(30));
      expect(patterns('kxmqzvbtwyhd'), isEmpty);
      expect(bits('abcdefghijkl'), lessThan(bits('kxmqzvbtwyhd')));
    });

    test('longer is never weaker for the same kind of password', () {
      expect(bits('kxmqzvbt'), lessThan(bits('kxmqzvbtwyhd')));
    });
  });
}
