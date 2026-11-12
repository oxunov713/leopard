// The QR login state machine, with fake time and a scripted repository.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/core/error/failures.dart';
import 'package:leopard_web/features/qr_login/domain/qr_login_repository.dart';
import 'package:leopard_web/features/qr_login/presentation/qr_login_cubit.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

/// A repository whose answers are queued by the test.
class ScriptedQrRepository implements QrLoginRepository {
  ScriptedQrRepository(this._now);

  final DateTime Function() _now;

  /// Answers for [poll], first in first out. When empty: `pending`.
  final List<Object> pollScript = [];

  /// When set, [begin] throws it.
  Object? beginError;

  /// When set, the next [poll] waits for it.
  Completer<QrPollOutcome>? heldPoll;

  final List<QrLoginAttempt> attempts = [];
  final List<DateTime> pollTimes = [];
  int abandoned = 0;

  @override
  Future<QrLoginAttempt> begin() async {
    final error = beginError;
    if (error != null) throw error;
    final n = attempts.length + 1;
    final attempt = QrLoginAttempt(
      sid: bytesOf(sidSize, n),
      pollToken: tokenOf(n),
      keyPair: X25519KeyPair(
        privateKey: bytesOf(x25519KeySize, 0x40 + n),
        publicKey: bytesOf(x25519KeySize, 0x80 + n),
      ),
      qrText: 'leopard://qr?v=1&sid=$n&pk=test',
      verifyCode: '${100000 + n}',
      expiresAt: _now().add(const Duration(seconds: 60)),
    );
    attempts.add(attempt);
    return attempt;
  }

  @override
  Future<QrPollOutcome> poll(QrLoginAttempt attempt) async {
    pollTimes.add(_now());
    final held = heldPoll;
    if (held != null) {
      heldPoll = null;
      return held.future;
    }
    if (pollScript.isEmpty) return QrPollOutcome.pending;
    final next = pollScript.removeAt(0);
    if (next is QrPollOutcome) return next;
    throw next;
  }

  @override
  void abandon(QrLoginAttempt attempt) {
    abandoned++;
    attempt.destroy();
  }
}

const rateLimited = RateLimitedException(
  statusCode: 429,
  code: 'rate_limited',
  message: 'x',
  retryAfter: Duration(seconds: 7),
);

const serverDown = ServerException(statusCode: 503, code: 'x', message: 'x');

void main() {
  /// Runs [body] with a cubit and repository on the fake clock.
  void run(
    void Function(FakeAsync async, QrLoginCubit cubit, ScriptedQrRepository r)
    body, {
    int maxAutoRenewals = 4,
  }) {
    fakeAsync((async) {
      DateTime now() => t0.add(async.elapsed);
      final repository = ScriptedQrRepository(now);
      final cubit = QrLoginCubit(
        repository,
        now: now,
        maxAutoRenewals: maxAutoRenewals,
      );
      body(async, cubit, repository);
      cubit.close();
      async.flushMicrotasks();
    });
  }

  void start(FakeAsync async, QrLoginCubit cubit) {
    cubit.start();
    async.flushMicrotasks();
  }

  test('shows the QR text, the code and a 60 s countdown', () {
    run((async, cubit, repository) {
      expect(cubit.state.status, QrLoginStatus.starting);
      start(async, cubit);

      expect(cubit.state.status, QrLoginStatus.waiting);
      expect(cubit.state.qrText, 'leopard://qr?v=1&sid=1&pk=test');
      expect(cubit.state.verifyCode, '100001');
      expect(cubit.state.secondsLeft, 60);
      expect(cubit.state.totalSeconds, 60);

      async.elapse(const Duration(seconds: 15));
      expect(cubit.state.secondsLeft, 45);
      expect(cubit.state.status, QrLoginStatus.waiting);
    });
  });

  test('polls once a second, one request at a time', () {
    run((async, cubit, repository) {
      start(async, cubit);
      async.elapse(const Duration(seconds: 5));
      expect(repository.pollTimes, hasLength(5));

      // A slow answer holds the next poll back.
      final slow = Completer<QrPollOutcome>();
      repository.heldPoll = slow;
      async.elapse(const Duration(seconds: 4));
      expect(repository.pollTimes, hasLength(6));
      slow.complete(QrPollOutcome.pending);
      async.elapse(const Duration(seconds: 1));
      expect(repository.pollTimes, hasLength(7));
    });
  });

  test('approval ends the attempt as signed in', () {
    run((async, cubit, repository) {
      start(async, cubit);
      repository.pollScript.addAll([
        QrPollOutcome.pending,
        QrPollOutcome.signedIn,
      ]);
      async.elapse(const Duration(seconds: 2));

      expect(cubit.state, const QrLoginState(status: QrLoginStatus.signedIn));
      // Nothing more is polled, and the ephemeral key is gone.
      async.elapse(const Duration(seconds: 30));
      expect(repository.pollTimes, hasLength(2));
      expect(repository.attempts.single.isDestroyed, isTrue);
      expect(repository.attempts.single.keyPair.privateKey, everyElement(0));
    });
  });

  test('rejection on the phone, then a new code on request', () {
    run((async, cubit, repository) {
      start(async, cubit);
      repository.pollScript.add(QrPollOutcome.rejected);
      async.elapse(const Duration(seconds: 1));

      expect(cubit.state.status, QrLoginStatus.rejected);
      expect(cubit.state.qrText, isNull);
      async.elapse(const Duration(seconds: 120));
      expect(repository.attempts, hasLength(1), reason: 'no automatic retry');

      start(async, cubit);
      expect(cubit.state.status, QrLoginStatus.waiting);
      expect(cubit.state.verifyCode, '100002');
    });
  });

  test('a consumed request is reported, not retried', () {
    run((async, cubit, repository) {
      start(async, cubit);
      repository.pollScript.add(QrPollOutcome.consumed);
      async.elapse(const Duration(seconds: 1));
      expect(cubit.state.status, QrLoginStatus.failed);
      expect(cubit.state.error, contains('already used'));
    });
  });

  group('expiry', () {
    test('an expired code is replaced by a new one', () {
      run((async, cubit, repository) {
        start(async, cubit);
        repository.pollScript.add(QrPollOutcome.expired);
        async.elapse(const Duration(seconds: 1));

        expect(cubit.state.status, QrLoginStatus.waiting);
        expect(cubit.state.verifyCode, '100002');
        expect(cubit.state.secondsLeft, 60);
        expect(repository.attempts.first.isDestroyed, isTrue);
      });
    });

    test('the local countdown renews even if polls do not get through', () {
      run((async, cubit, repository) {
        start(async, cubit);
        repository.heldPoll = Completer<QrPollOutcome>();
        async.elapse(const Duration(seconds: 60));
        expect(repository.attempts, hasLength(2));
        expect(cubit.state.verifyCode, '100002');
        expect(repository.attempts.first.keyPair.privateKey, everyElement(0));
      });
    });

    test('after the automatic renewals the page asks first', () {
      run((async, cubit, repository) {
        start(async, cubit);
        async.elapse(const Duration(seconds: 60 * 3));
        expect(repository.attempts, hasLength(3));
        expect(cubit.state.status, QrLoginStatus.expired);

        // A forgotten tab makes no more requests.
        final polls = repository.pollTimes.length;
        async.elapse(const Duration(minutes: 30));
        expect(repository.pollTimes, hasLength(polls));
        expect(repository.attempts, hasLength(3));

        start(async, cubit);
        expect(cubit.state.status, QrLoginStatus.waiting);
        expect(cubit.state.verifyCode, '100004');
      }, maxAutoRenewals: 2);
    });
  });

  group('backoff', () {
    test('network errors double the delay up to 10 s, then recover', () {
      run((async, cubit, repository) {
        start(async, cubit);
        repository.pollScript.addAll(List.filled(5, serverDown));
        async.elapse(const Duration(seconds: 40));

        final gaps = [
          for (var i = 1; i < repository.pollTimes.length; i++)
            repository.pollTimes[i]
                .difference(repository.pollTimes[i - 1])
                .inSeconds,
        ];
        // Five failures: wait 2, 4, 8, 10, 10; then back to every second.
        expect(gaps.take(7), [2, 4, 8, 10, 10, 1, 1]);
        expect(cubit.state.status, QrLoginStatus.waiting);
        expect(cubit.state.reconnecting, isFalse);
      });
    });

    test('the code stays on screen while reconnecting', () {
      run((async, cubit, repository) {
        start(async, cubit);
        repository.pollScript.add(serverDown);
        async.elapse(const Duration(seconds: 1));
        expect(cubit.state.status, QrLoginStatus.waiting);
        expect(cubit.state.reconnecting, isTrue);
        expect(cubit.state.qrText, isNotNull);
      });
    });

    test('429 waits for Retry-After', () {
      run((async, cubit, repository) {
        start(async, cubit);
        repository.pollScript.add(rateLimited);
        async.elapse(const Duration(seconds: 1));
        expect(repository.pollTimes, hasLength(1));
        async.elapse(const Duration(seconds: 6));
        expect(repository.pollTimes, hasLength(1));
        async.elapse(const Duration(seconds: 1));
        expect(repository.pollTimes, hasLength(2));
      });
    });
  });

  group('failures', () {
    test('the request cannot be created', () {
      run((async, cubit, repository) {
        repository.beginError = rateLimited;
        start(async, cubit);
        expect(cubit.state.status, QrLoginStatus.failed);
        expect(cubit.state.error, 'Too many attempts. Try again in 7 s.');
      });
    });

    test('an approval that does not decrypt stops the login', () {
      run((async, cubit, repository) {
        start(async, cubit);
        repository.pollScript.add(const ServerMismatchFailure('bad payload'));
        async.elapse(const Duration(seconds: 1));
        expect(cubit.state.status, QrLoginStatus.failed);
        expect(cubit.state.error, 'bad payload');
        expect(repository.attempts.single.isDestroyed, isTrue);
        async.elapse(const Duration(seconds: 30));
        expect(repository.pollTimes, hasLength(1));
      });
    });
  });

  test('leaving the page stops polling and wipes the key', () {
    fakeAsync((async) {
      DateTime now() => t0.add(async.elapsed);
      final repository = ScriptedQrRepository(now);
      final cubit = QrLoginCubit(repository, now: now)..start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 3));

      cubit.close();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 120));

      expect(repository.pollTimes, hasLength(3));
      expect(repository.attempts, hasLength(1));
      expect(repository.attempts.single.keyPair.privateKey, everyElement(0));
    });
  });

  test('an answer to an abandoned attempt is ignored', () {
    run((async, cubit, repository) {
      start(async, cubit);
      final stale = Completer<QrPollOutcome>();
      repository.heldPoll = stale;
      async.elapse(const Duration(seconds: 1));

      // The user asks for a new code while the poll is still in flight.
      start(async, cubit);
      stale.complete(QrPollOutcome.rejected);
      async.flushMicrotasks();

      expect(cubit.state.status, QrLoginStatus.waiting);
      expect(cubit.state.verifyCode, '100002');
    });
  });
}
