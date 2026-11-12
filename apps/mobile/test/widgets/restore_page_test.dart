import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_mobile/core/security/device_authenticator.dart';
import 'package:leopard_mobile/features/restore/presentation/restore_cubit.dart';
import 'package:leopard_mobile/features/restore/presentation/restore_page.dart';
import 'package:mocktail/mocktail.dart';

import 'support.dart';

void main() {
  late MockRestoreCubit cubit;

  setUp(() {
    cubit = MockRestoreCubit();
    when(
      () => cubit.submit(
        serverUrl: any(named: 'serverUrl'),
        deviceLabel: any(named: 'deviceLabel'),
        recoveryKey: any(named: 'recoveryKey'),
        masterPassword: any(named: 'masterPassword'),
        confirmation: any(named: 'confirmation'),
      ),
    ).thenAnswer((_) async {});
    when(cubit.openVault).thenAnswer((_) async {});
  });

  Future<void> pump(
    WidgetTester tester,
    RestoreState state, {
    DeviceLockStatus lockStatus = DeviceLockStatus.secured,
  }) async {
    givenState(cubit, state);
    await pumpPage(
      tester,
      const RestorePage(),
      providers: [BlocProvider<RestoreCubit>.value(value: cubit)],
      lockStatus: lockStatus,
    );
  }

  testWidgets('the form sends every field and warns what restoring does', (
    tester,
  ) async {
    await pump(tester, const RestoreState(), lockStatus: DeviceLockStatus.none);
    await tester.pump();
    expect(find.byKey(const Key('screen-lock-warning')), findsOneWidget);
    expect(find.textContaining('signs out every other phone'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('restore-server-url')),
      'https://vault.example.com',
    );
    await tester.enterText(
      find.byKey(const Key('restore-recovery-key')),
      'eaqs eize eutc okbj fivs yljo f4',
    );
    await tester.enterText(find.byKey(const Key('restore-password')), 'pw');
    await tester.enterText(
      find.byKey(const Key('restore-password-confirm')),
      'pw',
    );
    await tester.tap(find.byKey(const Key('restore-submit')));

    verify(
      () => cubit.submit(
        serverUrl: 'https://vault.example.com',
        deviceLabel: 'Android phone',
        recoveryKey: 'eaqs eize eutc okbj fivs yljo f4',
        masterPassword: 'pw',
        confirmation: 'pw',
      ),
    ).called(1);
  });

  testWidgets('secret fields are hidden from the keyboard', (tester) async {
    await pump(tester, const RestoreState());
    for (final key in const [
      Key('restore-recovery-key'),
      Key('restore-password'),
      Key('restore-password-confirm'),
    ]) {
      final field = textFieldOf(tester, key);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.autofillHints, isNull);
    }
    expect(
      textFieldOf(tester, const Key('restore-password')).obscureText,
      isTrue,
    );
  });

  testWidgets('errors are shown on the form', (tester) async {
    await pump(tester, const RestoreState(error: malformedRecoveryKeyMessage));
    expect(find.text(malformedRecoveryKeyMessage), findsOneWidget);
  });

  testWidgets('done: says the old phone is out and VK was not rotated', (
    tester,
  ) async {
    await pump(tester, const RestoreState(step: RestoreStep.done));
    expect(find.byKey(const Key('restore-old-phone-notice')), findsOneWidget);
    expect(
      find.textContaining('old phone has been disconnected'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('restore-vk-notice')), findsOneWidget);
    expect(find.textContaining('vault key was not changed'), findsOneWidget);
    expect(find.byKey(const Key('restore-recovery-key')), findsNothing);

    await tester.tap(find.byKey(const Key('restore-open')));
    verify(cubit.openVault).called(1);
  });
}
