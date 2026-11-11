import 'package:bloc_test/bloc_test.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/features/qr_approve/domain/qr_login_repository.dart';
import 'package:leopard_mobile/features/qr_approve/presentation/qr_approve_cubit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  late MockQrLoginRepository repository;
  final now = DateTime.utc(2026, 11, 11, 10, 0, 5);
  final request = QrLoginRequest(
    sid: bytesOf(sidSize, 1),
    browserPub: bytesOf(x25519KeySize, 2),
    verifyCode: '459154',
    ip: '203.0.113.50',
    browser: 'Firefox',
    platform: 'Linux',
    userAgent: 'Mozilla/5.0',
    createdAt: DateTime.utc(2026, 11, 11, 10),
    expiresAt: DateTime.utc(2026, 11, 11, 10, 1),
  );
  const scannedText = 'leopard://qr?v=1&sid=x&pk=y';

  setUpAll(() => registerFallbackValue(request));

  setUp(() {
    repository = MockQrLoginRepository();
    when(() => repository.load(any())).thenAnswer((_) async => request);
    when(
      () => repository.confirmPresence(),
    ).thenAnswer((_) async => PresenceResult.confirmed);
    when(() => repository.approve(any())).thenAnswer((_) async {});
    when(() => repository.reject(any())).thenAnswer((_) async {});
  });

  QrApproveCubit build() => QrApproveCubit(repository, now: () => now);

  blocTest<QrApproveCubit, QrApproveState>(
    'a scanned code is fetched and shown for review',
    build: build,
    act: (cubit) => cubit.scanned(scannedText),
    expect: () => [
      const QrApproveState(status: QrApproveStatus.loading),
      QrApproveState(status: QrApproveStatus.review, request: request),
    ],
    verify: (_) {
      verify(() => repository.load(scannedText)).called(1);
      // Showing the request approves nothing.
      verifyNever(() => repository.confirmPresence());
      verifyNever(() => repository.approve(any()));
    },
  );

  test('only the first code is used while one is being handled', () async {
    final cubit = build();
    await cubit.scanned(scannedText);
    await cubit.scanned('leopard://qr?v=1&sid=other&pk=other');
    verify(() => repository.load(any())).called(1);
    await cubit.close();
  });

  group('approve', () {
    blocTest<QrApproveCubit, QrApproveState>(
      'screen lock first, then the approval is sent',
      build: build,
      act: (cubit) async {
        await cubit.scanned(scannedText);
        await cubit.approve();
      },
      skip: 2,
      expect: () => [
        QrApproveState(
          status: QrApproveStatus.authenticating,
          request: request,
        ),
        QrApproveState(status: QrApproveStatus.submitting, request: request),
        QrApproveState(status: QrApproveStatus.approved, request: request),
      ],
      verify: (_) => verifyInOrder([
        () => repository.confirmPresence(),
        () => repository.approve(request),
      ]),
    );

    test('without the screen lock nothing is sent', () async {
      when(
        () => repository.confirmPresence(),
      ).thenAnswer((_) async => PresenceResult.denied);
      final cubit = build();
      await cubit.scanned(scannedText);
      await cubit.approve();

      expect(cubit.state.status, QrApproveStatus.review);
      expect(cubit.state.request, request);
      expect(cubit.state.message, contains('Unlock with your screen lock'));
      verifyNever(() => repository.approve(any()));

      // The user can try again.
      when(
        () => repository.confirmPresence(),
      ).thenAnswer((_) async => PresenceResult.confirmed);
      await cubit.approve();
      expect(cubit.state.status, QrApproveStatus.approved);
      verify(() => repository.approve(request)).called(1);
      await cubit.close();
    });

    test(
      'a screen lock that stays unconfirmed never reaches approve',
      () async {
        // Nothing but PresenceResult.confirmed may lead to a signature.
        for (final result in [
          PresenceResult.denied,
          PresenceResult.passwordRequired,
        ]) {
          when(
            () => repository.confirmPresence(),
          ).thenAnswer((_) async => result);
          final cubit = build();
          await cubit.scanned(scannedText);
          await cubit.approve();
          expect(cubit.state.status, isNot(QrApproveStatus.approved));
          await cubit.close();
        }
        verifyNever(() => repository.approve(any()));
      },
    );

    test('approve does nothing before a request is on screen', () async {
      final cubit = build();
      await cubit.approve();
      expect(cubit.state, const QrApproveState());
      verifyNever(() => repository.confirmPresence());
      await cubit.close();
    });

    test('a second tap while the prompt is up is ignored', () async {
      final cubit = build();
      await cubit.scanned(scannedText);
      final first = cubit.approve();
      await cubit.approve();
      await first;
      verify(() => repository.confirmPresence()).called(1);
      verify(() => repository.approve(any())).called(1);
      await cubit.close();
    });

    for (final (error, text) in <(Object, String)>[
      (
        const GoneException(statusCode: 410, code: 'qr_expired', message: 'x'),
        'expired',
      ),
      (
        const ConflictException(
          statusCode: 409,
          code: 'qr_not_pending',
          message: 'x',
        ),
        'already',
      ),
      (
        const ForbiddenException(
          statusCode: 403,
          code: 'bad_signature',
          message: 'x',
        ),
        'signature',
      ),
    ]) {
      test('server refusal: $text', () async {
        when(() => repository.approve(any())).thenThrow(error);
        final cubit = build();
        await cubit.scanned(scannedText);
        await cubit.approve();
        expect(cubit.state.status, QrApproveStatus.failed);
        expect(cubit.state.message, contains(text));
        await cubit.close();
      });
    }
  });

  group('reject', () {
    blocTest<QrApproveCubit, QrApproveState>(
      'tells the server and needs no screen lock',
      build: build,
      act: (cubit) async {
        await cubit.scanned(scannedText);
        await cubit.reject();
      },
      skip: 2,
      expect: () => [
        QrApproveState(status: QrApproveStatus.submitting, request: request),
        QrApproveState(status: QrApproveStatus.rejected, request: request),
      ],
      verify: (_) {
        verify(() => repository.reject(request)).called(1);
        verifyNever(() => repository.confirmPresence());
        verifyNever(() => repository.approve(any()));
      },
    );
  });

  group('a code that must not be trusted', () {
    test('is refused with the reason, and can be scanned again', () async {
      when(() => repository.load(any())).thenThrow(
        const QrRejectedFailure(
          'The server reported a different browser key than the QR code. '
          'The login was not approved.',
        ),
      );
      final cubit = build();
      await cubit.scanned(scannedText);

      expect(cubit.state.status, QrApproveStatus.failed);
      expect(cubit.state.request, isNull);
      expect(cubit.state.message, contains('different browser key'));
      verifyNever(() => repository.approve(any()));

      cubit.scanAgain();
      expect(cubit.state, const QrApproveState());
      await cubit.close();
    });
  });

  group('expiry', () {
    test('an undecided request expires after its 60 seconds', () async {
      final soon = QrLoginRequest(
        sid: request.sid,
        browserPub: request.browserPub,
        verifyCode: request.verifyCode,
        ip: request.ip,
        browser: request.browser,
        platform: request.platform,
        userAgent: request.userAgent,
        createdAt: request.createdAt,
        expiresAt: now.add(const Duration(milliseconds: 40)),
      );
      when(() => repository.load(any())).thenAnswer((_) async => soon);
      final cubit = build();
      await cubit.scanned(scannedText);
      expect(cubit.state.status, QrApproveStatus.review);

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(cubit.state.status, QrApproveStatus.expired);
      await cubit.approve();
      verifyNever(() => repository.confirmPresence());
      verifyNever(() => repository.approve(any()));
      await cubit.close();
    });

    test('expiry during the screen-lock prompt cancels the approval', () async {
      final soon = QrLoginRequest(
        sid: request.sid,
        browserPub: request.browserPub,
        verifyCode: request.verifyCode,
        ip: request.ip,
        browser: request.browser,
        platform: request.platform,
        userAgent: request.userAgent,
        createdAt: request.createdAt,
        expiresAt: now.add(const Duration(milliseconds: 40)),
      );
      when(() => repository.load(any())).thenAnswer((_) async => soon);
      when(() => repository.confirmPresence()).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return PresenceResult.confirmed;
      });
      final cubit = build();
      await cubit.scanned(scannedText);
      await cubit.approve();

      expect(cubit.state.status, QrApproveStatus.expired);
      verifyNever(() => repository.approve(any()));
      await cubit.close();
    });
  });

  group('phone without a screen lock', () {
    setUp(() {
      when(
        () => repository.confirmPresence(),
      ).thenAnswer((_) async => PresenceResult.passwordRequired);
      when(
        () => repository.verifyMasterPassword(any()),
      ).thenAnswer((_) async => true);
    });

    test('asks for the master password instead, sending nothing', () async {
      final cubit = build();
      await cubit.scanned(scannedText);
      await cubit.approve();

      expect(cubit.state.status, QrApproveStatus.passwordRequired);
      expect(cubit.state.request, request);
      expect(cubit.state.message, contains('no screen lock'));
      verifyNever(() => repository.approve(any()));
      await cubit.close();
    });

    test('the right password approves', () async {
      final cubit = build();
      await cubit.scanned(scannedText);
      await cubit.approve();
      final states = <QrApproveStatus>[];
      final sub = cubit.stream.listen((s) => states.add(s.status));
      await cubit.approveWithPassword('right');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(states, [
        QrApproveStatus.verifyingPassword,
        QrApproveStatus.submitting,
        QrApproveStatus.approved,
      ]);
      verifyInOrder([
        () => repository.verifyMasterPassword('right'),
        () => repository.approve(request),
      ]);
      await cubit.close();
    });

    test('a wrong password sends nothing and lets the user retry', () async {
      when(
        () => repository.verifyMasterPassword('wrong'),
      ).thenAnswer((_) async => false);
      final cubit = build();
      await cubit.scanned(scannedText);
      await cubit.approve();
      await cubit.approveWithPassword('wrong');

      expect(cubit.state.status, QrApproveStatus.passwordRequired);
      expect(cubit.state.message, contains('Wrong master password'));
      verifyNever(() => repository.approve(any()));

      await cubit.approveWithPassword('right');
      expect(cubit.state.status, QrApproveStatus.approved);
      await cubit.close();
    });

    test('an empty password never reaches the KDF', () async {
      final cubit = build();
      await cubit.scanned(scannedText);
      await cubit.approve();
      await cubit.approveWithPassword('');

      expect(cubit.state.status, QrApproveStatus.passwordRequired);
      verifyNever(() => repository.verifyMasterPassword(any()));
      await cubit.close();
    });

    test('the password is not accepted outside its prompt', () async {
      final cubit = build();
      await cubit.scanned(scannedText);
      await cubit.approveWithPassword('right'); // still in review
      expect(cubit.state.status, QrApproveStatus.review);
      verifyNever(() => repository.verifyMasterPassword(any()));
      verifyNever(() => repository.approve(any()));
      await cubit.close();
    });

    test('cancel goes back to review', () async {
      final cubit = build();
      await cubit.scanned(scannedText);
      await cubit.approve();
      cubit.cancelPassword();
      expect(cubit.state.status, QrApproveStatus.review);
      await cubit.close();
    });
  });
}
