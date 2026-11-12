import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_mobile/core/security/device_authenticator.dart';
import 'package:leopard_mobile/features/unlock/presentation/unlock_cubit.dart';
import 'package:leopard_mobile/features/unlock/presentation/unlock_page.dart';
import 'package:mocktail/mocktail.dart';

import 'support.dart';

void main() {
  late MockUnlockCubit cubit;

  setUp(() {
    cubit = MockUnlockCubit();
    when(cubit.start).thenAnswer((_) async {});
    when(cubit.unlockWithDeviceCredential).thenAnswer((_) async {});
    when(() => cubit.unlockWithMasterPassword(any())).thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester, UnlockState state) async {
    givenState(cubit, state);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpPage(
      tester,
      const UnlockPage(),
      providers: [BlocProvider<UnlockCubit>.value(value: cubit)],
    );
    await tester.pump();
  }

  testWidgets('asks for the screen lock as soon as it is on screen', (
    tester,
  ) async {
    await pump(tester, const UnlockState());
    verify(cubit.start).called(1);
  });

  testWidgets('offers the screen lock when the phone has one, and the '
      'master password as an explicit option', (tester) async {
    await pump(tester, const UnlockState(deviceLock: DeviceLockStatus.secured));
    expect(find.byKey(const Key('unlock-device')), findsOneWidget);
    expect(find.text('Unlock with screen lock'), findsOneWidget);
    expect(find.byKey(const Key('unlock-password')), findsOneWidget);
    expect(find.text('Unlock with master password'), findsOneWidget);
    expect(find.byKey(const Key('unlock-no-screen-lock')), findsNothing);

    await tester.tap(find.byKey(const Key('unlock-device')));
    verify(cubit.unlockWithDeviceCredential).called(1);
  });

  testWidgets('without a screen lock there is only the password', (
    tester,
  ) async {
    await pump(tester, const UnlockState(deviceLock: DeviceLockStatus.none));
    expect(find.byKey(const Key('unlock-device')), findsNothing);
    expect(find.byKey(const Key('unlock-password')), findsOneWidget);
    expect(find.byKey(const Key('unlock-no-screen-lock')), findsOneWidget);
  });

  testWidgets('the master password field is hardened', (tester) async {
    await pump(tester, const UnlockState());
    final field = textFieldOf(tester, const Key('unlock-password'));
    expect(field.obscureText, isTrue);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
    expect(field.autofillHints, isNull);
    expect(field.keyboardType, TextInputType.visiblePassword);
  });

  testWidgets('submits the typed password and empties the field', (
    tester,
  ) async {
    await pump(tester, const UnlockState());
    await tester.enterText(
      find.byKey(const Key('unlock-password')),
      'my master password',
    );
    await tester.tap(find.byKey(const Key('unlock-submit')));
    await tester.pump();

    verify(
      () => cubit.unlockWithMasterPassword('my master password'),
    ).called(1);
    expect(
      textFieldOf(tester, const Key('unlock-password')).controller!.text,
      isEmpty,
    );
  });

  testWidgets('shows the error and disables input while deriving', (
    tester,
  ) async {
    await pump(tester, const UnlockState(message: 'Wrong master password.'));
    expect(find.text('Wrong master password.'), findsOneWidget);

    await pump(tester, const UnlockState(status: UnlockStatus.deriving));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('unlock-submit')))
          .onPressed,
      isNull,
    );
    expect(find.text('Checking…'), findsOneWidget);
  });
}
