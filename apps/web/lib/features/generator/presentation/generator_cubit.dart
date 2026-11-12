import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

enum GeneratorMode { password, passphrase }

final class GeneratorState extends Equatable {
  const GeneratorState({
    this.mode = GeneratorMode.password,
    this.value = '',
    this.entropyBits = 0,
    this.length = 20,
    this.classes = const {
      CharClass.lowercase,
      CharClass.uppercase,
      CharClass.digits,
      CharClass.symbols,
    },
    this.excludeAmbiguous = false,
    this.wordCount = 6,
    this.separator = '-',
    this.capitalize = false,
    this.includeNumber = false,
  });

  final GeneratorMode mode;

  /// The generated secret.
  final String value;

  /// Entropy of the generator settings (not an estimate of [value]).
  final double entropyBits;

  // Password options.
  final int length;
  final Set<CharClass> classes;
  final bool excludeAmbiguous;

  // Passphrase options.
  final int wordCount;
  final String separator;
  final bool capitalize;
  final bool includeNumber;

  PasswordOptions get passwordOptions => PasswordOptions(
    length: length,
    classes: classes,
    excludeAmbiguous: excludeAmbiguous,
  );

  PassphraseOptions get passphraseOptions => PassphraseOptions(
    wordCount: wordCount,
    separator: separator,
    capitalize: capitalize,
    includeNumber: includeNumber,
  );

  GeneratorState copyWith({
    GeneratorMode? mode,
    String? value,
    double? entropyBits,
    int? length,
    Set<CharClass>? classes,
    bool? excludeAmbiguous,
    int? wordCount,
    String? separator,
    bool? capitalize,
    bool? includeNumber,
  }) => GeneratorState(
    mode: mode ?? this.mode,
    value: value ?? this.value,
    entropyBits: entropyBits ?? this.entropyBits,
    length: length ?? this.length,
    classes: classes ?? this.classes,
    excludeAmbiguous: excludeAmbiguous ?? this.excludeAmbiguous,
    wordCount: wordCount ?? this.wordCount,
    separator: separator ?? this.separator,
    capitalize: capitalize ?? this.capitalize,
    includeNumber: includeNumber ?? this.includeNumber,
  );

  @override
  List<Object?> get props => [
    mode,
    value,
    entropyBits,
    length,
    classes,
    excludeAmbiguous,
    wordCount,
    separator,
    capitalize,
    includeNumber,
  ];
}

/// Password and passphrase generator. All randomness comes from
/// `leopard_core` (`Random.secure`).
class GeneratorCubit extends Cubit<GeneratorState> {
  GeneratorCubit() : super(const GeneratorState()) {
    regenerate();
  }

  static const int minLength = 8;
  static const int maxLength = 64;
  static const int minWords = 4;
  static const int maxWords = 12;

  void regenerate() => _generate(state);

  void setMode(GeneratorMode mode) => _generate(state.copyWith(mode: mode));

  void setLength(int length) =>
      _generate(state.copyWith(length: length.clamp(minLength, maxLength)));

  /// Turns a character class on or off. The last class cannot be removed.
  void toggleClass(CharClass charClass) {
    final classes = {...state.classes};
    if (!classes.remove(charClass)) {
      classes.add(charClass);
    }
    if (classes.isEmpty) return;
    _generate(state.copyWith(classes: classes));
  }

  void setExcludeAmbiguous(bool value) =>
      _generate(state.copyWith(excludeAmbiguous: value));

  void setWordCount(int count) =>
      _generate(state.copyWith(wordCount: count.clamp(minWords, maxWords)));

  void setSeparator(String separator) =>
      _generate(state.copyWith(separator: separator));

  void setCapitalize(bool value) =>
      _generate(state.copyWith(capitalize: value));

  void setIncludeNumber(bool value) =>
      _generate(state.copyWith(includeNumber: value));

  void _generate(GeneratorState next) {
    switch (next.mode) {
      case GeneratorMode.password:
        final options = next.passwordOptions;
        emit(
          next.copyWith(
            value: generatePassword(options),
            entropyBits: options.entropyBits,
          ),
        );
      case GeneratorMode.passphrase:
        final options = next.passphraseOptions;
        emit(
          next.copyWith(
            value: generatePassphrase(options),
            entropyBits: options.entropyBits,
          ),
        );
    }
  }
}
