// The whole widget tree with fakes below the repositories: routing follows
// the lock state, and decrypted items follow it too.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/app/app.dart';
import 'package:leopard_mobile/app/dependencies.dart';
import 'package:leopard_mobile/core/security/biometric_authenticator.dart';
import 'package:leopard_mobile/core/session/vault_session.dart';
import 'package:leopard_mobile/core/storage/device_store.dart';
import 'package:leopard_mobile/features/setup/presentation/setup_page.dart';
import 'package:leopard_mobile/features/unlock/presentation/unlock_page.dart';
import 'package:leopard_mobile/features/vault/domain/vault_repository.dart';
import 'package:leopard_mobile/features/vault/presentation/vault_list_page.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fakes.dart';
import 'support.dart';

void main() {
  late MockDeviceStore store;
  late MockRemoteVault remote;
  late MockSecretClipboard clipboard;
  late MockUnlockRepository unlock;
  late MockVaultRepository vault;
  late VaultSession session;
  late UnlockedVault keys;

  setUp(() {
    store = MockDeviceStore();
    remote = MockRemoteVault();
    clipboard = MockSecretClipboard();
    unlock = MockUnlockRepository();
    vault = MockVaultRepository();
    session = VaultSession();
    keys = UnlockedVault(
      deviceId: deviceIdA,
      vaultKey: bytesOf(keySize, 1),
      itemKey: bytesOf(keySize, 2),
      deviceSeed: bytesOf(ed25519SeedSize, 3),
    );
    when(clipboard.clearNow).thenAnswer((_) async {});
    when(
      unlock.biometricAvailability,
    ).thenAnswer((_) async => BiometricAvailability.notEnrolled);
    when(() => unlock.unlockWithMasterPassword(any())).thenAnswer((_) async {
      session.open(keys);
      return true;
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

  AppDependencies dependencies() => AppDependencies(
    deviceStore: store,
    session: session,
    remote: remote,
    clipboard: clipboard,
    setupRepository: MockSetupRepository(),
    unlockRepository: unlock,
    vaultRepository: vault,
    qrLoginRepository: MockQrLoginRepository(),
    sessionsRepository: MockSessionsRepository(),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  testWidgets('a phone without a vault opens the setup wizard', (tester) async {
    useTallSurface(tester);
    when(store.readRegistration).thenAnswer((_) async => null);

    await tester.pumpWidget(LeopardApp(dependencies: dependencies()));
    await settle(tester);

    expect(find.byType(SetupPage), findsOneWidget);
    expect(find.byType(VaultListPage), findsNothing);
  });

  testWidgets('a set-up phone starts locked; unlocking loads the vault and '
      'locking drops it', (tester) async {
    useTallSurface(tester);
    when(store.readRegistration).thenAnswer(
      (_) async => DeviceRegistration(
        serverUrl: serverUrl,
        deviceId: deviceIdA,
        deviceLabel: 'Pixel 9',
      ),
    );

    await tester.pumpWidget(LeopardApp(dependencies: dependencies()));
    await settle(tester);

    // Locked: no vault content exists in the tree, nothing was fetched.
    expect(find.byType(UnlockPage), findsOneWidget);
    expect(find.byType(VaultListPage), findsNothing);
    verifyNever(() => vault.sync());

    await tester.enterText(find.byKey(const Key('unlock-password')), 'pw');
    await tester.tap(find.byKey(const Key('unlock-submit')));
    await settle(tester);

    expect(find.byType(VaultListPage), findsOneWidget);
    expect(find.byType(UnlockPage), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    verify(() => vault.sync()).called(1);

    await tester.tap(find.byKey(const Key('vault-lock')));
    await settle(tester);

    expect(find.byType(UnlockPage), findsOneWidget);
    expect(find.byType(VaultListPage), findsNothing);
    expect(find.text('Alpha'), findsNothing);
    expect(session.isUnlocked, isFalse);
    expect(keys.vaultKey, everyElement(0));
    expect(keys.vaultKey, isA<Uint8List>());
    verify(remote.forgetSession).called(1);
  });
}
