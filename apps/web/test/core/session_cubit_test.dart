// The rules that end a web session (crypto-spec §11), with fake time.
import 'package:fake_async/fake_async.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/core/session/session_cubit.dart';
import 'package:leopard_web/core/session/vault_session.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

void main() {
  late FakeItemServer api;
  late MockSecretClipboard clipboard;
  late VaultSession session;

  setUp(() {
    api = FakeItemServer();
    clipboard = MockSecretClipboard();
    when(() => clipboard.clearNow()).thenAnswer((_) async {});
    session = VaultSession();
  });

  /// Runs [body] with a cubit whose clock is the fake clock.
  void run(
    void Function(FakeAsync async, SessionCubit cubit) body, {
    Duration hiddenLimit = const Duration(seconds: 30),
  }) {
    fakeAsync((async) {
      final cubit = SessionCubit(
        session: session,
        api: api,
        clipboard: clipboard,
        now: () => t0.add(async.elapsed),
        hiddenLimit: hiddenLimit,
      );
      body(async, cubit);
      cubit.close();
      async.flushMicrotasks();
    });
  }

  /// Signs in and lets the session stream deliver.
  UnlockedVault signIn(FakeAsync async) {
    final vault = unlockedVault();
    session.open(vault);
    async.flushMicrotasks();
    return vault;
  }

  test('starts signed out and follows the vault session', () {
    run((async, cubit) {
      expect(cubit.state, const SessionState.signedOut());
      signIn(async);
      expect(cubit.state, const SessionState.unlocked());
    });
  });

  group('idle lock', () {
    test('locks after 300 s without activity and wipes the keys', () {
      run((async, cubit) {
        final vault = signIn(async);
        async.elapse(const Duration(seconds: 299));
        expect(cubit.state.isUnlocked, isTrue);

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(
          cubit.state,
          const SessionState.signedOut(reason: SignOutReason.idle),
        );
        expect(session.isUnlocked, isFalse);
        expect(vault.vaultKey, everyElement(0));
        expect(vault.itemKey, everyElement(0));
        expect(api.signedIn, isFalse, reason: 'the token is dropped');
        expect(api.logouts, 1, reason: 'the server is told to revoke');
        verify(() => clipboard.clearNow()).called(greaterThan(0));
      });
    });

    test('activity moves the deadline', () {
      run((async, cubit) {
        signIn(async);
        async.elapse(const Duration(seconds: 200));
        cubit.recordActivity();
        async.elapse(const Duration(seconds: 299));
        expect(cubit.state.isUnlocked, isTrue);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(cubit.state.reason, SignOutReason.idle);
      });
    });

    test('warns during the last minute, and activity clears the warning', () {
      run((async, cubit) {
        signIn(async);
        async.elapse(const Duration(seconds: 239));
        expect(cubit.state.locksInSeconds, isNull);
        async.elapse(const Duration(seconds: 1));
        expect(cubit.state.locksInSeconds, 60);
        async.elapse(const Duration(seconds: 50));
        expect(cubit.state.locksInSeconds, 10);

        cubit.recordActivity();
        expect(cubit.state, const SessionState.unlocked());
      });
    });

    test('a page that is only open sends no heartbeat at all', () {
      run((async, cubit) {
        signIn(async);
        async.elapse(const Duration(seconds: 299));
        expect(api.heartbeats, 0);
      });
    });
  });

  group('heartbeat', () {
    test('is sent because of activity, at most every 30 s', () {
      run((async, cubit) {
        signIn(async);
        // Inside the first window: nothing yet.
        async.elapse(const Duration(seconds: 5));
        cubit.recordActivity();
        async.flushMicrotasks();
        expect(api.heartbeats, 0);

        // The window ends: one trailing heartbeat covers that activity.
        async.elapse(const Duration(seconds: 25));
        expect(api.heartbeats, 1);

        // No further activity, no further heartbeats.
        async.elapse(const Duration(seconds: 120));
        expect(api.heartbeats, 1);

        // Activity after a quiet period is reported at once.
        cubit.recordActivity();
        async.flushMicrotasks();
        expect(api.heartbeats, 2);

        // A burst of activity is still one heartbeat per window.
        for (var i = 0; i < 20; i++) {
          async.elapse(const Duration(seconds: 1));
          cubit.recordActivity();
        }
        expect(api.heartbeats, 2);
        async.elapse(const Duration(seconds: 10));
        expect(api.heartbeats, 3);
      });
    });

    test('a failed heartbeat does not lock by itself', () {
      final mock = MockLeopardApi();
      when(() => mock.sessionEnded).thenAnswer((_) => const Stream.empty());
      when(() => mock.heartbeat()).thenThrow(
        const ServerException(statusCode: 503, code: 'x', message: 'x'),
      );
      fakeAsync((async) {
        final cubit = SessionCubit(
          session: session,
          api: mock,
          clipboard: clipboard,
          now: () => t0.add(async.elapsed),
        );
        signIn(async);
        async.elapse(const Duration(seconds: 40));
        cubit.recordActivity();
        async.flushMicrotasks();
        verify(() => mock.heartbeat()).called(1);
        expect(cubit.state.isUnlocked, isTrue);
        cubit.close();
        async.flushMicrotasks();
      });
    });
  });

  test('401 on any request: keys and token are wiped, no logout call', () {
    run((async, cubit) {
      final vault = signIn(async);
      api.revokedWith = 'session_revoked';

      // Any authenticated request, here a vault sync.
      api.listItems().ignore();
      async.flushMicrotasks();

      expect(
        cubit.state,
        const SessionState.signedOut(reason: SignOutReason.ended),
      );
      expect(vault.vaultKey, everyElement(0));
      expect(api.signedIn, isFalse);
      expect(api.logouts, 0);
    });
  });

  test('401 on the heartbeat locks', () {
    run((async, cubit) {
      signIn(async);
      api.revokedWith = 'session_expired';
      async.elapse(const Duration(seconds: 31));
      cubit.recordActivity();
      async.flushMicrotasks();
      expect(cubit.state.reason, SignOutReason.ended);
    });
  });

  test('12 h absolute limit, however active the user is', () {
    run((async, cubit) {
      signIn(async);
      const step = Duration(minutes: 4);
      var elapsed = Duration.zero;
      while (elapsed + step < const Duration(hours: 12)) {
        async.elapse(step);
        elapsed += step;
        cubit.recordActivity();
      }
      expect(cubit.state.isUnlocked, isTrue);
      async.elapse(const Duration(hours: 12) - elapsed);
      async.flushMicrotasks();
      expect(cubit.state.reason, SignOutReason.expired);
      expect(session.isUnlocked, isFalse);
    });
  });

  group('tab visibility', () {
    test('a tab hidden for 30 s locks', () {
      run((async, cubit) {
        signIn(async);
        cubit.onHidden();
        async.elapse(const Duration(seconds: 29));
        expect(cubit.state.isUnlocked, isTrue);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(cubit.state.reason, SignOutReason.hidden);
      });
    });

    test('coming back sooner keeps the session', () {
      run((async, cubit) {
        signIn(async);
        cubit.onHidden();
        async.elapse(const Duration(seconds: 20));
        cubit.onVisible();
        async.elapse(const Duration(seconds: 40));
        expect(cubit.state.isUnlocked, isTrue);
      });
    });

    test('a suspended timer is caught up when the tab is shown again', () {
      fakeAsync((async) {
        // The clock runs ahead of the timers, as in a throttled tab.
        var skew = Duration.zero;
        final cubit = SessionCubit(
          session: session,
          api: api,
          clipboard: clipboard,
          now: () => t0.add(async.elapsed + skew),
        );
        signIn(async);
        cubit.onHidden();
        skew = const Duration(minutes: 2);
        cubit.onVisible();
        async.flushMicrotasks();
        expect(cubit.state.reason, SignOutReason.hidden);
        cubit.close();
        async.flushMicrotasks();
      });
    });

    test('closing the tab logs out', () {
      run((async, cubit) {
        final vault = signIn(async);
        cubit.onPageClosing();
        async.flushMicrotasks();
        expect(vault.vaultKey, everyElement(0));
        expect(api.logouts, 1);
        expect(cubit.state.reason, SignOutReason.closing);
        expect(describeSignOut(cubit.state.reason), isNull);
      });
    });
  });

  test('logout button: server call, wipe, notice that can be dismissed', () {
    run((async, cubit) {
      final vault = signIn(async);
      cubit.logout();
      async.flushMicrotasks();

      expect(api.logouts, 1);
      expect(vault.vaultKey, everyElement(0));
      expect(
        cubit.state,
        const SessionState.signedOut(reason: SignOutReason.userRequest),
      );
      expect(describeSignOut(cubit.state.reason), 'You are logged out.');

      cubit.dismissNotice();
      expect(cubit.state, const SessionState.signedOut());

      // Signing in again starts a fresh idle period.
      api.signedIn = true;
      signIn(async);
      async.elapse(const Duration(seconds: 299));
      expect(cubit.state.isUnlocked, isTrue);
    });
  });

  test('nothing happens while signed out', () {
    run((async, cubit) {
      cubit
        ..recordActivity()
        ..onHidden()
        ..tick();
      async.elapse(const Duration(minutes: 10));
      expect(cubit.state, const SessionState.signedOut());
      expect(api.heartbeats, 0);
    });
  });
}
