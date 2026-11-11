import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/features/qr_approve/domain/qr_login_repository.dart';
import 'package:leopard_mobile/features/qr_approve/presentation/qr_approve_cubit.dart';
import 'package:leopard_mobile/features/qr_approve/presentation/qr_approve_page.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fakes.dart';
import 'support.dart';

void main() {
  late MockQrApproveCubit cubit;
  final request = QrLoginRequest(
    sid: bytesOf(sidSize, 1),
    browserPub: bytesOf(x25519KeySize, 2),
    verifyCode: '459154',
    ip: '203.0.113.50',
    browser: 'Firefox',
    platform: 'Linux',
    userAgent: 'Mozilla/5.0 (X11; Linux x86_64)',
    createdAt: DateTime.utc(2026, 11, 11, 10),
    expiresAt: DateTime.utc(2026, 11, 11, 10, 1),
  );

  setUp(() {
    cubit = MockQrApproveCubit();
    when(cubit.approve).thenAnswer((_) async {});
    when(cubit.reject).thenAnswer((_) async {});
    when(() => cubit.scanned(any())).thenAnswer((_) async {});
  });

  // A stand-in for the camera: a button that "sees" a code.
  Widget fakeScanner(BuildContext context, ValueChanged<String> onCode) =>
      TextButton(
        key: const Key('fake-scanner'),
        onPressed: () => onCode('leopard://qr?v=1&sid=x&pk=y'),
        child: const Text('scan'),
      );

  Future<void> pump(WidgetTester tester, QrApproveState state) async {
    givenState(cubit, state);
    await pumpPage(
      tester,
      QrApprovePage(scannerBuilder: fakeScanner),
      providers: [BlocProvider<QrApproveCubit>.value(value: cubit)],
    );
  }

  testWidgets('scanning hands the code text to the cubit', (tester) async {
    await pump(tester, const QrApproveState());
    await tester.tap(find.byKey(const Key('fake-scanner')));
    verify(() => cubit.scanned('leopard://qr?v=1&sid=x&pk=y')).called(1);
  });

  testWidgets('review shows the code in large type with the instruction, '
      'the IP and the browser', (tester) async {
    await pump(
      tester,
      QrApproveState(status: QrApproveStatus.review, request: request),
    );

    final code = tester.widget<Text>(find.byKey(const Key('qr-verify-code')));
    expect(code.data, '459 154');
    expect(code.style!.fontSize, greaterThanOrEqualTo(40));
    expect(code.style!.fontFamily, 'monospace');
    expect(
      tester.widget<Text>(find.byKey(const Key('qr-instruction'))).data,
      'MATCH THIS WITH THE BROWSER',
    );
    expect(find.text('203.0.113.50'), findsOneWidget);
    expect(find.text('Firefox on Linux'), findsOneWidget);
    expect(find.text('Mozilla/5.0 (X11; Linux x86_64)'), findsOneWidget);
    // No camera while a request is under review.
    expect(find.byKey(const Key('fake-scanner')), findsNothing);
  });

  testWidgets('Approve and Reject call the cubit', (tester) async {
    await pump(
      tester,
      QrApproveState(status: QrApproveStatus.review, request: request),
    );
    await tester.tap(find.byKey(const Key('qr-approve')));
    verify(cubit.approve).called(1);
    await tester.tap(find.byKey(const Key('qr-reject')));
    verify(cubit.reject).called(1);
  });

  testWidgets('both buttons are disabled while the biometric prompt is up', (
    tester,
  ) async {
    await pump(
      tester,
      QrApproveState(status: QrApproveStatus.authenticating, request: request),
    );
    await tester.tap(find.byKey(const Key('qr-approve')), warnIfMissed: false);
    await tester.tap(find.byKey(const Key('qr-reject')), warnIfMissed: false);
    verifyNever(cubit.approve);
    verifyNever(cubit.reject);
    expect(find.text('WAITING FOR BIOMETRIC…'), findsOneWidget);
  });

  testWidgets('a refused biometric is explained on the review screen', (
    tester,
  ) async {
    await pump(
      tester,
      QrApproveState(
        status: QrApproveStatus.review,
        request: request,
        message:
            'Biometric confirmation is required to approve a login. '
            'Nothing was sent.',
      ),
    );
    expect(find.textContaining('Nothing was sent'), findsOneWidget);
    expect(find.byKey(const Key('qr-approve')), findsOneWidget);
  });

  testWidgets('outcomes', (tester) async {
    await pump(
      tester,
      QrApproveState(status: QrApproveStatus.approved, request: request),
    );
    expect(find.text('Login approved'), findsOneWidget);

    await pump(
      tester,
      QrApproveState(status: QrApproveStatus.rejected, request: request),
    );
    expect(find.text('Login rejected'), findsOneWidget);

    await pump(
      tester,
      const QrApproveState(
        status: QrApproveStatus.failed,
        message: 'The server reported a different browser key.',
      ),
    );
    expect(find.text('Not approved'), findsOneWidget);
    expect(
      find.text('The server reported a different browser key.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('qr-outcome-action')));
    verify(cubit.scanAgain).called(1);
  });
}
