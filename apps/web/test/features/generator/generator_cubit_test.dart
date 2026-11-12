import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/features/generator/presentation/generator_cubit.dart';
import 'package:test/test.dart';

void main() {
  test('starts with a 20-character password of all four classes', () async {
    final cubit = GeneratorCubit();
    final state = cubit.state;
    expect(state.mode, GeneratorMode.password);
    expect(state.value, hasLength(20));
    for (final charClass in CharClass.values) {
      expect(
        state.value.split('').any(charClass.characters.contains),
        isTrue,
        reason: charClass.name,
      );
    }
    expect(state.entropyBits, greaterThan(120));
    await cubit.close();
  });

  test('regenerate gives a different value', () async {
    final cubit = GeneratorCubit();
    final first = cubit.state.value;
    cubit.regenerate();
    expect(cubit.state.value, isNot(first));
    await cubit.close();
  });

  test('length and character classes are applied', () async {
    final cubit = GeneratorCubit()
      ..setLength(32)
      ..toggleClass(CharClass.symbols)
      ..toggleClass(CharClass.uppercase)
      ..toggleClass(CharClass.lowercase);
    expect(cubit.state.value, matches(RegExp(r'^\d{32}$')));

    // The last class cannot be switched off.
    cubit.toggleClass(CharClass.digits);
    expect(cubit.state.classes, {CharClass.digits});

    cubit
      ..setLength(1000)
      ..setExcludeAmbiguous(true);
    expect(cubit.state.length, GeneratorCubit.maxLength);
    expect(cubit.state.value.contains(RegExp('[01]')), isFalse);
    cubit.setLength(1);
    expect(cubit.state.length, GeneratorCubit.minLength);
    await cubit.close();
  });

  test('passphrase mode', () async {
    final cubit = GeneratorCubit()
      ..setMode(GeneratorMode.passphrase)
      ..setWordCount(5)
      ..setSeparator('.');
    var words = cubit.state.value.split('.');
    expect(words, hasLength(5));
    expect(words, everyElement(isIn(effShortWordlist)));
    expect(cubit.state.entropyBits, closeTo(5 * 10.34, 0.1));

    cubit
      ..setCapitalize(true)
      ..setIncludeNumber(true);
    words = cubit.state.value.split('.');
    expect(words, everyElement(matches(RegExp(r'^[A-Z][a-z-]*\d?$'))));
    expect(cubit.state.value, contains(RegExp(r'\d')));

    cubit.setWordCount(99);
    expect(cubit.state.wordCount, GeneratorCubit.maxWords);
    await cubit.close();
  });
}
