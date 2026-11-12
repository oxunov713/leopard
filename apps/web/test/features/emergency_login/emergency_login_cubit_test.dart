import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/core/error/failures.dart';
import 'package:leopard_web/features/emergency_login/domain/emergency_login_repository.dart';
import 'package:leopard_web/features/emergency_login/presentation/emergency_login_cubit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  late MockEmergencyLoginRepository repository;

  setUp(() => repository = MockEmergencyLoginRepository());

  void loginAnswers(Future<void> Function(Invocation invocation) answer) {
    when(
      () => repository.login(
        masterPassword: any(named: 'masterPassword'),
        totpCode: any(named: 'totpCode'),
        onPhase: any(named: 'onPhase'),
      ),
    ).thenAnswer(answer);
  }

  void loginThrows(Object error) => loginAnswers((_) async => throw error);

  Future<EmergencyLoginState> submit(EmergencyLoginCubit cubit) async {
    await cubit.submit(masterPassword: 'pw', totpCode: '492039');
    return cubit.state;
  }

  test('reports each phase and the elapsed time, then signs in', () {
    fakeAsync((async) {
      final gate = Completer<void>();
      loginAnswers((invocation) async {
        final onPhase =
            invocation.namedArguments[#onPhase]
                as void Function(EmergencyLoginPhase)?;
        onPhase!(EmergencyLoginPhase.fetchingParameters);
        onPhase(EmergencyLoginPhase.derivingKey);
        await gate.future;
        onPhase(EmergencyLoginPhase.verifying);
      });
      final cubit = EmergencyLoginCubit(repository);
      expect(cubit.state, const EmergencyLoginState());

      cubit.submit(masterPassword: 'pw', totpCode: '492039');
      async.flushMicrotasks();
      expect(cubit.state.isWorking, isTrue);
      expect(cubit.state.phase, EmergencyLoginPhase.derivingKey);
      expect(cubit.state.canSubmit, isFalse);

      async.elapse(const Duration(seconds: 7));
      expect(cubit.state.phase, EmergencyLoginPhase.derivingKey);

      // A second click while working starts nothing.
      cubit.submit(masterPassword: 'pw', totpCode: '492039');
      async.flushMicrotasks();

      gate.complete();
      async.flushMicrotasks();
      expect(
        cubit.state,
        const EmergencyLoginState(status: EmergencyLoginStatus.signedIn),
      );
      verify(
        () => repository.login(
          masterPassword: 'pw',
          totpCode: '492039',
          onPhase: any(named: 'onPhase'),
        ),
      ).called(1);
      cubit.close();
      async.flushMicrotasks();
    });
  });

  test('wrong credentials or a replayed code: one clear message', () async {
    loginThrows(
      const UnauthorizedException(
        statusCode: 401,
        code: 'invalid_credentials',
        message: 'x',
      ),
    );
    final cubit = EmergencyLoginCubit(repository);
    final state = await submit(cubit);

    expect(state.status, EmergencyLoginStatus.idle);
    expect(state.error, contains('master password or the code is wrong'));
    expect(state.error, contains('already'));
    expect(state.canSubmit, isTrue);
    await cubit.close();
  });

  test('429: the form is blocked until Retry-After has passed', () {
    fakeAsync((async) {
      loginThrows(
        const RateLimitedException(
          statusCode: 429,
          code: 'rate_limited',
          message: 'x',
          retryAfter: Duration(seconds: 90),
        ),
      );
      final cubit = EmergencyLoginCubit(repository)
        ..submit(masterPassword: 'pw', totpCode: '492039');
      async.flushMicrotasks();

      expect(cubit.state.error, 'Too many login attempts. Try again in 2 min.');
      expect(cubit.state.retryInSeconds, 90);
      expect(cubit.state.canSubmit, isFalse);

      async.elapse(const Duration(seconds: 30));
      expect(cubit.state.retryInSeconds, 60);
      cubit.submit(masterPassword: 'pw', totpCode: '492039');
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 60));
      expect(cubit.state.retryInSeconds, isNull);
      expect(cubit.state.canSubmit, isTrue);
      expect(cubit.state.error, isNotNull);
      verify(
        () => repository.login(
          masterPassword: any(named: 'masterPassword'),
          totpCode: any(named: 'totpCode'),
          onPhase: any(named: 'onPhase'),
        ),
      ).called(1);
      cubit.close();
      async.flushMicrotasks();
    });
  });

  test('429 without Retry-After names the limit', () async {
    loginThrows(
      const RateLimitedException(
        statusCode: 429,
        code: 'rate_limited',
        message: 'x',
      ),
    );
    final cubit = EmergencyLoginCubit(repository);
    final state = await submit(cubit);
    expect(state.error, contains('5 in 15 minutes'));
    expect(state.canSubmit, isTrue);
    await cubit.close();
  });

  test('other failures use the common messages', () async {
    final cubit = EmergencyLoginCubit(repository);

    loginThrows(const ValidationFailure('Enter the master password.'));
    expect((await submit(cubit)).error, 'Enter the master password.');

    loginThrows(
      const NotFoundException(
        statusCode: 404,
        code: 'not_initialised',
        message: 'x',
      ),
    );
    expect((await submit(cubit)).error, contains('no vault yet'));

    loginThrows(TimeoutException('x'));
    expect((await submit(cubit)).error, 'The server did not answer in time.');
    await cubit.close();
  });
}
