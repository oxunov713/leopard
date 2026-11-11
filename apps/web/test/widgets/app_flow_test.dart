// The whole widget tree with fakes below the repositories: routing follows
// the session state, and decrypted items follow it too.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/app/app.dart';
import 'package:leopard_web/app/dependencies.dart';
import 'package:leopard_web/app/router.dart';
import 'package:leopard_web/core/security/password_handoff.dart';
import 'package:leopard_web/core/session/session_cubit.dart';
import 'package:leopard_web/core/session/vault_session.dart';
import 'package:leopard_web/features/emergency_login/presentation/emergency_login_page.dart';
import 'package:leopard_web/features/generator/presentation/generator_page.dart';
import 'package:leopard_web/features/qr_login/domain/qr_login_repository.dart';
import 'package:leopard_web/features/qr_login/presentation/login_page.dart';
import 'package:leopard_web/features/vault/domain/vault_repository.dart';
import 'package:leopard_web/features/vault/presentation/item_edit_page.dart';
import 'package:leopard_web/features/vault/presentation/vault_list_page.dart';
import 'package:mocktail/mocktail.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../support/fakes.dart';

QrLoginAttempt attemptOf(int n) => QrLoginAttempt(
  sid: bytesOf(sidSize, n),
  pollToken: tokenOf(n),
  keyPair: X25519KeyPair(
    privateKey: bytesOf(x25519KeySize, 0x40 + n),
    publicKey: bytesOf(x25519KeySize, 0x80 + n),
  ),
  qrText: 'leopard://qr?v=1&sid=test$n&pk=test',
  verifyCode: '459154',
  // Far from the test clock on purpose: the cubit then falls back to the
  // protocol's 60 seconds.
  expiresAt: DateTime.utc(2030),
);

void main() {
  late FakeItemServer api;
  late MockSecretClipboard clipboard;
  late MockQrLoginRepository qr;
  late MockEmergencyLoginRepository emergency;
  late MockVaultRepository vault;
  late VaultSession session;
  late UnlockedVault keys;
  late QrPollOutcome nextPoll;

  setUpAll(() => registerFallbackValue(attemptOf(0)));

  setUp(() {
    api = FakeItemServer()..signedIn = false;
    clipboard = MockSecretClipboard();
    qr = MockQrLoginRepository();
    emergency = MockEmergencyLoginRepository();
    vault = MockVaultRepository();
    session = VaultSession();
    keys = unlockedVault();
    nextPoll = QrPollOutcome.pending;
    var attempts = 0;
    when(clipboard.clearNow).thenAnswer((_) async {});
    when(qr.begin).thenAnswer((_) async => attemptOf(++attempts));
    when(() => qr.abandon(any())).thenReturn(null);
    // The phone "approves" when the test flips [nextPoll].
    when(() => qr.poll(any())).thenAnswer((_) async {
      if (nextPoll == QrPollOutcome.signedIn) {
        api.signedIn = true;
        session.open(keys);
      }
      return nextPoll;
    });
    when(() => vault.sync()).thenAnswer(
      (_) async => SyncDelta(
        upserts: [entry(itemIdA, login('Alpha'))],
        deletedIds: const {},
        unreadableIds: const {},
        serverTime: '2026-11-11T10:00:10Z',
      ),
    );
  });

  // Deadlines follow the test's fake clock, like its timers.
  AppDependencies dependencies(WidgetTester tester) => AppDependencies(
    now: () => tester.binding.clock.now(),
    session: session,
    api: api,
    clipboard: clipboard,
    passwordHandoff: PasswordHandoff(),
    qrLoginRepository: qr,
    emergencyLoginRepository: emergency,
    vaultRepository: vault,
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  /// Removes the app so that its timers are cancelled before the test ends.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  void useSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('starts on the QR code; approval opens the vault; logout wipes '
      'it', (tester) async {
    useSurface(tester, const Size(1280, 1600));
    await tester.pumpWidget(LeopardApp(dependencies: dependencies(tester)));
    await settle(tester);

    // Signed out: no vault content exists in the tree, nothing was fetched.
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(VaultListPage), findsNothing);
    final code = tester.widget<QrImageView>(find.byKey(const Key('login-qr')));
    expect(code, isNotNull);
    expect(find.text('459 154'), findsOneWidget);
    verifyNever(() => vault.sync());

    nextPoll = QrPollOutcome.signedIn;
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);

    expect(find.byType(VaultListPage), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    verify(() => vault.sync()).called(1);
    // The QR page is gone, and with it the polling.
    nextPoll = QrPollOutcome.pending;
    clearInteractions(qr);
    await tester.pump(const Duration(seconds: 5));
    verifyNever(() => qr.poll(any()));

    await tester.tap(find.byKey(const Key('shell-logout')));
    await settle(tester);

    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(VaultListPage), findsNothing);
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('You are logged out.'), findsOneWidget);
    expect(session.isUnlocked, isFalse);
    expect(keys.vaultKey, everyElement(0));
    expect(keys.vaultKey, isA<Uint8List>());
    expect(api.logouts, 1);
    expect(api.signedIn, isFalse);

    await unmount(tester);
  });

  testWidgets('a 401 from the server sends the browser back to the login', (
    tester,
  ) async {
    useSurface(tester, const Size(1280, 1600));
    await tester.pumpWidget(LeopardApp(dependencies: dependencies(tester)));
    await settle(tester);
    nextPoll = QrPollOutcome.signedIn;
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.byType(VaultListPage), findsOneWidget);
    nextPoll = QrPollOutcome.pending;

    // The phone revokes the session; the next request finds out.
    api.revokedWith = 'session_revoked';
    api.listItems().ignore();
    await settle(tester);

    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
    expect(find.byKey(const Key('sign-out-notice')), findsOneWidget);
    expect(keys.vaultKey, everyElement(0));
    expect(api.logouts, 0);

    await unmount(tester);
  });

  testWidgets('five minutes without activity lock the vault; activity '
      'keeps it open', (tester) async {
    useSurface(tester, const Size(1280, 1600));
    await tester.pumpWidget(LeopardApp(dependencies: dependencies(tester)));
    await settle(tester);
    nextPoll = QrPollOutcome.signedIn;
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    nextPoll = QrPollOutcome.pending;
    expect(find.byType(VaultListPage), findsOneWidget);

    // Typing in the search field is activity.
    await tester.pump(const Duration(seconds: 200));
    await tester.tap(find.byKey(const Key('vault-search')));
    await tester.pump(const Duration(seconds: 200));
    expect(find.byType(VaultListPage), findsOneWidget);
    expect(api.heartbeats, greaterThan(0));

    // The last minute shows a warning.
    await tester.pump(const Duration(seconds: 60));
    expect(find.byKey(const Key('idle-warning')), findsOneWidget);

    await tester.pump(const Duration(seconds: 60));
    await settle(tester);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.textContaining('Locked after 5 minutes'), findsOneWidget);
    expect(keys.vaultKey, everyElement(0));

    await unmount(tester);
  });

  testWidgets('the generator is reachable without a login and cannot save', (
    tester,
  ) async {
    useSurface(tester, const Size(1280, 1600));
    await tester.pumpWidget(LeopardApp(dependencies: dependencies(tester)));
    await settle(tester);

    await tester.tap(find.byKey(const Key('login-generator')));
    await settle(tester);

    expect(find.byType(GeneratorPage), findsOneWidget);
    expect(find.byKey(const Key('generator-value')), findsOneWidget);
    expect(find.byKey(const Key('strength-label')), findsOneWidget);
    expect(find.byKey(const Key('generator-save')), findsNothing);
    // Leaving the QR page stopped its attempt.
    verify(() => qr.abandon(any())).called(1);

    await tester.tap(find.byKey(const Key('generator-to-login')));
    await settle(tester);
    expect(find.byType(LoginPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('login-emergency')));
    await settle(tester);
    expect(find.byType(EmergencyLoginPage), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('signed in: a generated password is handed to a new login '
      'item, on a narrow window too', (tester) async {
    useSurface(tester, const Size(420, 1600));
    await tester.pumpWidget(LeopardApp(dependencies: dependencies(tester)));
    await settle(tester);
    nextPoll = QrPollOutcome.signedIn;
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    nextPoll = QrPollOutcome.pending;

    await tester.tap(find.text('Generator'));
    await settle(tester);
    final generated = tester
        .widget<SelectableText>(find.byKey(const Key('generator-value')))
        .data!;
    expect(generated, hasLength(20));

    await tester.tap(find.byKey(const Key('generator-save')));
    await settle(tester);

    expect(find.byType(ItemEditPage), findsOneWidget);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('edit-password')),
        matching: find.byType(TextField),
        matchRoot: true,
      ),
    );
    expect(field.controller!.text, generated);

    await unmount(tester);
  });

  test('redirects', () {
    const out = SessionStatus.signedOut;
    const unlocked = SessionStatus.unlocked;
    expect(redirectFor(out, '/login'), isNull);
    expect(redirectFor(out, '/login/emergency'), isNull);
    expect(redirectFor(out, '/login/generator'), isNull);
    expect(redirectFor(out, '/'), '/login');
    expect(redirectFor(out, '/vault'), '/login');
    expect(redirectFor(out, '/vault/item/$itemIdA'), '/login');
    expect(redirectFor(out, '/generator'), '/login');
    expect(redirectFor(out, '/loginx'), '/login');
    expect(redirectFor(unlocked, '/login'), '/vault');
    expect(redirectFor(unlocked, '/login/emergency'), '/vault');
    expect(redirectFor(unlocked, '/'), '/vault');
    expect(redirectFor(unlocked, '/vault'), isNull);
    expect(redirectFor(unlocked, '/generator'), isNull);
    expect(redirectFor(unlocked, '/vault/new/login'), isNull);
  });
}
