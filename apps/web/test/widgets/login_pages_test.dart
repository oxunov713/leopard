import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_web/app/theme.dart';
import 'package:leopard_web/core/session/session_cubit.dart';
import 'package:leopard_web/core/widgets/secret_text_field.dart';
import 'package:leopard_web/features/emergency_login/domain/emergency_login_repository.dart';
import 'package:leopard_web/features/emergency_login/presentation/emergency_login_cubit.dart';
import 'package:leopard_web/features/emergency_login/presentation/emergency_login_page.dart';
import 'package:leopard_web/features/qr_login/presentation/login_page.dart';
import 'package:leopard_web/features/qr_login/presentation/qr_login_cubit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qr_flutter/qr_flutter.dart';

class MockQrLoginCubit extends MockCubit<QrLoginState>
    implements QrLoginCubit {}

class MockEmergencyLoginCubit extends MockCubit<EmergencyLoginState>
    implements EmergencyLoginCubit {}

class MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

/// Makes [cubit] report [state] and emit nothing else.
void givenState<S>(MockCubit<S> cubit, S state) {
  whenListen(cubit, Stream<S>.empty(), initialState: state);
}

Future<void> pumpPage(
  WidgetTester tester,
  Widget page,
  List<BlocProvider<dynamic>> providers,
) async {
  tester.view.physicalSize = const Size(1280, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: providers,
      child: MaterialApp(theme: buildLeopardTheme(), home: page),
    ),
  );
}

void main() {
  group('LoginPage', () {
    late MockQrLoginCubit qr;
    late MockSessionCubit session;

    setUp(() {
      qr = MockQrLoginCubit();
      session = MockSessionCubit();
      givenState(session, const SessionState.signedOut());
      when(() => qr.start()).thenAnswer((_) async {});
    });

    Future<void> pump(WidgetTester tester, QrLoginState state) {
      givenState(qr, state);
      return pumpPage(tester, const LoginPage(), [
        BlocProvider<QrLoginCubit>.value(value: qr),
        BlocProvider<SessionCubit>.value(value: session),
      ]);
    }

    testWidgets('renders the QR text, the code and the countdown', (
      tester,
    ) async {
      const text = 'leopard://qr?v=1&sid=VlzLuUi5e5gU1cCAVI0A5Q&pk=test';
      await pump(
        tester,
        const QrLoginState(
          status: QrLoginStatus.waiting,
          qrText: text,
          verifyCode: '459154',
          secondsLeft: 42,
        ),
      );

      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('459 154'), findsOneWidget);
      expect(find.text('New code in 42 s'), findsOneWidget);
      // The text of the code itself is not printed anywhere.
      expect(find.textContaining('leopard://'), findsNothing);
    });

    testWidgets('says when polls are failing', (tester) async {
      await pump(
        tester,
        const QrLoginState(
          status: QrLoginStatus.waiting,
          qrText: 'leopard://qr?v=1&sid=a&pk=b',
          verifyCode: '000001',
          secondsLeft: 10,
          reconnecting: true,
        ),
      );
      expect(find.text('Connection problem. Retrying…'), findsOneWidget);
      expect(find.text('000 001'), findsOneWidget);
    });

    for (final (status, key, message) in [
      (QrLoginStatus.rejected, 'qr-rejected', 'rejected on the phone'),
      (QrLoginStatus.expired, 'qr-expired', 'The code expired'),
    ]) {
      testWidgets('${status.name}: no code, and a button for a new one', (
        tester,
      ) async {
        await pump(tester, QrLoginState(status: status));

        expect(find.byKey(Key(key)), findsOneWidget);
        expect(find.textContaining(message), findsOneWidget);
        expect(find.byType(QrImageView), findsNothing);

        await tester.tap(find.byKey(const Key('qr-new-code')));
        verify(() => qr.start()).called(1);
      });
    }

    testWidgets('shows the error of a failed attempt', (tester) async {
      await pump(
        tester,
        const QrLoginState(
          status: QrLoginStatus.failed,
          error: 'Cannot reach the server. Check the connection.',
        ),
      );
      expect(
        find.text('Cannot reach the server. Check the connection.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('qr-new-code')), findsOneWidget);
    });

    testWidgets('explains why the browser was signed out', (tester) async {
      givenState(
        session,
        const SessionState.signedOut(reason: SignOutReason.ended),
      );
      await pump(tester, const QrLoginState());
      expect(find.byKey(const Key('sign-out-notice')), findsOneWidget);
      expect(
        find.textContaining('The server ended this session'),
        findsOneWidget,
      );
    });
  });

  group('EmergencyLoginPage', () {
    late MockEmergencyLoginCubit cubit;

    setUp(() {
      cubit = MockEmergencyLoginCubit();
      when(
        () => cubit.submit(
          masterPassword: any(named: 'masterPassword'),
          totpCode: any(named: 'totpCode'),
        ),
      ).thenAnswer((_) async {});
    });

    Future<void> pump(WidgetTester tester, EmergencyLoginState state) {
      givenState(cubit, state);
      return pumpPage(tester, const EmergencyLoginPage(), [
        BlocProvider<EmergencyLoginCubit>.value(value: cubit),
      ]);
    }

    testWidgets('submits the password as typed and a 6-digit code', (
      tester,
    ) async {
      await pump(tester, const EmergencyLoginState());

      await tester.enterText(
        find.byKey(const Key('emergency-password')),
        ' pass word ',
      );
      // Anything but digits is dropped, and only six fit.
      await tester.enterText(
        find.byKey(const Key('emergency-code')),
        '492 039x77',
      );
      await tester.tap(find.byKey(const Key('emergency-submit')));

      verify(
        () => cubit.submit(masterPassword: ' pass word ', totpCode: '492039'),
      ).called(1);
    });

    testWidgets('the password field is masked and kept from the keyboard', (
      tester,
    ) async {
      await pump(tester, const EmergencyLoginState());
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(SecretTextField),
          matching: find.byType(TextField),
        ),
      );
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.autofillHints, isNull);
    });

    testWidgets('shows progress instead of the button while deriving', (
      tester,
    ) async {
      await pump(
        tester,
        const EmergencyLoginState(
          status: EmergencyLoginStatus.working,
          phase: EmergencyLoginPhase.derivingKey,
          elapsedSeconds: 7,
        ),
      );
      expect(find.byKey(const Key('emergency-working')), findsOneWidget);
      expect(find.byKey(const Key('emergency-submit')), findsNothing);
      expect(find.textContaining('Deriving the key'), findsOneWidget);
      expect(find.textContaining('7 s'), findsOneWidget);
    });

    testWidgets('shows the error and blocks the button during a rate limit', (
      tester,
    ) async {
      await pump(
        tester,
        const EmergencyLoginState(
          error: 'Too many login attempts. Try again in 2 min.',
          retryInSeconds: 90,
        ),
      );
      expect(find.byKey(const Key('emergency-error')), findsOneWidget);
      expect(find.text('WAIT 90 S'), findsOneWidget);
      await tester.tap(find.byKey(const Key('emergency-submit')));
      verifyNever(
        () => cubit.submit(
          masterPassword: any(named: 'masterPassword'),
          totpCode: any(named: 'totpCode'),
        ),
      );
    });
  });
}
