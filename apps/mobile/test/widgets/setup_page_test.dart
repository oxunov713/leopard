import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_mobile/core/security/device_authenticator.dart';
import 'package:leopard_mobile/features/setup/presentation/setup_cubit.dart';
import 'package:leopard_mobile/features/setup/presentation/setup_page.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'support.dart';

const recoveryKey = 'EAQS-EIZE-EUTC-OKBJ-FIVS-YLJO-F4';
const totpUri =
    'otpauth://totp/Leopard%3APixel?secret=JBSWY3DPEHPK3PXP&issuer=Leopard'
    '&algorithm=SHA1&digits=6&period=30';

void main() {
  late MockSetupCubit cubit;

  setUp(() {
    cubit = MockSetupCubit();
    when(
      () => cubit.submitServer(
        serverUrl: any(named: 'serverUrl'),
        deviceLabel: any(named: 'deviceLabel'),
        setupToken: any(named: 'setupToken'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => cubit.submitPassword(
        password: any(named: 'password'),
        confirmation: any(named: 'confirmation'),
      ),
    ).thenAnswer((_) async {});
    when(() => cubit.submitTotpCode(any())).thenAnswer((_) async {});
  });

  Future<void> pump(
    WidgetTester tester,
    SetupState state, {
    DeviceLockStatus lockStatus = DeviceLockStatus.secured,
  }) async {
    givenState(cubit, state);
    await pumpPage(
      tester,
      const SetupPage(),
      providers: [BlocProvider<SetupCubit>.value(value: cubit)],
      lockStatus: lockStatus,
    );
  }

  testWidgets('warns on a phone without a screen lock, not otherwise', (
    tester,
  ) async {
    await pump(tester, const SetupState(), lockStatus: DeviceLockStatus.none);
    await tester.pump();
    expect(find.byKey(const Key('screen-lock-warning')), findsOneWidget);

    await pump(tester, const SetupState());
    await tester.pump();
    expect(find.byKey(const Key('screen-lock-warning')), findsNothing);
  });

  testWidgets('server step sends address, phone name and setup token', (
    tester,
  ) async {
    await pump(tester, const SetupState());
    await tester.enterText(
      find.byKey(const Key('setup-server-url')),
      'https://vault.example.com',
    );
    await tester.enterText(find.byKey(const Key('setup-token')), 's3tup');
    await tester.tap(find.byKey(const Key('setup-server-continue')));

    verify(
      () => cubit.submitServer(
        serverUrl: 'https://vault.example.com',
        deviceLabel: 'Android phone',
        setupToken: 's3tup',
      ),
    ).called(1);
    // The setup token is a secret too.
    expect(
      textFieldOf(
        tester,
        const Key('setup-token'),
      ).enableIMEPersonalizedLearning,
      isFalse,
    );
  });

  testWidgets('server step shows why an address was refused', (tester) async {
    await pump(
      tester,
      const SetupState(error: 'Unencrypted http is not allowed.'),
    );
    expect(find.text('Unencrypted http is not allowed.'), findsOneWidget);
  });

  testWidgets('password step: hardened fields and a strength meter', (
    tester,
  ) async {
    await pump(
      tester,
      const SetupState(
        step: SetupStep.password,
        passwordBits: 31,
        passwordProblem:
            'Too easy to guess. Make it longer or less '
            'predictable.',
      ),
    );
    for (final key in const [
      Key('setup-password'),
      Key('setup-password-confirm'),
    ]) {
      final field = textFieldOf(tester, key);
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.autofillHints, isNull);
    }
    final label = tester.widget<Text>(find.byKey(const Key('strength-label')));
    expect(label.data, contains('Weak'));
    expect(label.data, contains('31 bits'));
    expect(label.data, contains('Too easy to guess'));

    await tester.enterText(find.byKey(const Key('setup-password')), 'abc');
    verify(() => cubit.passwordChanged('abc')).called(1);
  });

  testWidgets('password step submits both entries', (tester) async {
    await pump(tester, const SetupState(step: SetupStep.password));
    await tester.enterText(find.byKey(const Key('setup-password')), 'one');
    await tester.enterText(
      find.byKey(const Key('setup-password-confirm')),
      'two',
    );
    await tester.tap(find.byKey(const Key('setup-password-continue')));
    verify(
      () => cubit.submitPassword(password: 'one', confirmation: 'two'),
    ).called(1);
  });

  testWidgets('recovery key is shown in groups and must be acknowledged', (
    tester,
  ) async {
    await pump(
      tester,
      const SetupState(
        step: SetupStep.recoveryKey,
        recoveryKey: recoveryKey,
        challengeGroups: [1, 4],
      ),
    );
    for (final group in recoveryKey.split('-')) {
      expect(find.text(group), findsOneWidget);
    }
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('setup-recovery-continue')),
          )
          .onPressed,
      isNull,
      reason: 'cannot continue before "I wrote it down"',
    );

    await tester.tap(find.byKey(const Key('setup-recovery-ack')));
    verify(() => cubit.acknowledgeRecoveryKey(true)).called(1);
  });

  testWidgets('recovery key: continue is enabled once acknowledged', (
    tester,
  ) async {
    await pump(
      tester,
      const SetupState(
        step: SetupStep.recoveryKey,
        recoveryKey: recoveryKey,
        recoveryAcknowledged: true,
        challengeGroups: [1, 4],
      ),
    );
    await tester.tap(find.byKey(const Key('setup-recovery-continue')));
    verify(cubit.continueFromRecoveryKey).called(1);
  });

  testWidgets('recovery check asks for the two chosen groups, without '
      'showing the key', (tester) async {
    await pump(
      tester,
      const SetupState(
        step: SetupStep.recoveryCheck,
        recoveryKey: recoveryKey,
        recoveryAcknowledged: true,
        challengeGroups: [1, 4],
      ),
    );
    expect(find.text('Group 2'), findsOneWidget);
    expect(find.text('Group 5'), findsOneWidget);
    expect(find.text('EIZE'), findsNothing);
    expect(find.text('FIVS'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('setup-recovery-group-0')),
      'eize',
    );
    await tester.enterText(
      find.byKey(const Key('setup-recovery-group-1')),
      'FIVS',
    );
    await tester.tap(find.byKey(const Key('setup-recovery-check-continue')));
    verify(() => cubit.submitRecoveryCheck(['eize', 'FIVS'])).called(1);
  });

  testWidgets('TOTP step shows the otpauth URI as a QR code and the secret', (
    tester,
  ) async {
    await pump(
      tester,
      const SetupState(
        step: SetupStep.totp,
        recoveryKey: recoveryKey,
        totpUri: totpUri,
        totpSecret: 'JBSWY3DPEHPK3PXP',
      ),
    );
    expect(find.byType(QrImageView), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('setup-totp-secret'))).data,
      'JBSW Y3DP EHPK 3PXP',
    );

    await tester.enterText(find.byKey(const Key('setup-totp-code')), '123456');
    await tester.tap(find.byKey(const Key('setup-finish')));
    verify(() => cubit.submitTotpCode('123456')).called(1);
  });
}
