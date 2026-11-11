import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/core/error/failures.dart';
import 'package:leopard_mobile/core/lock/app_lock_cubit.dart';
import 'package:leopard_mobile/core/session/vault_session.dart';
import 'package:leopard_mobile/core/storage/device_store.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

void main() {
  late MockDeviceStore store;
  late MockRemoteVault remote;
  late MockSecretClipboard clipboard;
  late VaultSession session;
  late DateTime now;
  late UnlockedVault vault;

  final registration = DeviceRegistration(
    serverUrl: serverUrl,
    deviceId: deviceIdA,
    deviceLabel: 'Pixel 9',
  );

  setUp(() {
    store = MockDeviceStore();
    remote = MockRemoteVault();
    clipboard = MockSecretClipboard();
    session = VaultSession();
    now = DateTime.utc(2026, 11, 11, 10);
    vault = UnlockedVault(
      deviceId: deviceIdA,
      vaultKey: bytesOf(keySize, 1),
      itemKey: bytesOf(keySize, 2),
      deviceSeed: bytesOf(ed25519SeedSize, 3),
    );
    when(() => store.readRegistration()).thenAnswer((_) async => registration);
    when(() => store.erase()).thenAnswer((_) async {});
    when(() => clipboard.clearNow()).thenAnswer((_) async {});
  });

  AppLockCubit build({Duration autoLockAfter = const Duration(seconds: 30)}) =>
      AppLockCubit(
        store: store,
        session: session,
        remote: remote,
        clipboard: clipboard,
        now: () => now,
        autoLockAfter: autoLockAfter,
      );

  /// Lets the broadcast stream of [VaultSession] deliver.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('start', () {
    test('no registration: setup is needed', () async {
      when(() => store.readRegistration()).thenAnswer((_) async => null);
      final cubit = build();
      expect(cubit.state.status, AppLockStatus.starting);
      await cubit.start();
      expect(cubit.state.status, AppLockStatus.needsSetup);
      await cubit.close();
    });

    test('registered: starts locked', () async {
      final cubit = build();
      await cubit.start();
      expect(cubit.state.status, AppLockStatus.locked);
      await cubit.close();
    });

    test('unreadable storage is an error state, not a fresh setup', () async {
      when(() => store.readRegistration()).thenThrow(const StorageFailure());
      final cubit = build();
      await cubit.start();
      expect(cubit.state.status, AppLockStatus.storageError);
      expect(cubit.state.message, isNotNull);
      await cubit.close();
    });
  });

  test('follows the session: unlocked when a vault key is in memory', () async {
    final cubit = build();
    await cubit.start();
    session.open(vault);
    await settle();
    expect(cubit.state.status, AppLockStatus.unlocked);
    await cubit.close();
  });

  group('lock', () {
    test('zeroes the keys, drops the token and clears the clipboard', () async {
      final cubit = build();
      await cubit.start();
      session.open(vault);
      await settle();

      cubit.lock();
      await settle();

      expect(cubit.state.status, AppLockStatus.locked);
      expect(session.isUnlocked, isFalse);
      expect(vault.vaultKey, everyElement(0));
      expect(vault.itemKey, everyElement(0));
      expect(vault.deviceSeed, everyElement(0));
      expect(() => session.require, throwsA(isA<VaultLockedFailure>()));
      verify(() => remote.forgetSession()).called(1);
      verify(() => clipboard.clearNow()).called(1);
      await cubit.close();
    });
  });

  group('auto-lock after 30 s in the background', () {
    Future<AppLockCubit> unlocked({
      Duration autoLockAfter = const Duration(seconds: 30),
    }) async {
      final cubit = build(autoLockAfter: autoLockAfter);
      await cubit.start();
      session.open(vault);
      await settle();
      return cubit;
    }

    test('back within 30 s: still unlocked', () async {
      final cubit = await unlocked();
      cubit.onBackgrounded();
      now = now.add(const Duration(seconds: 29));
      cubit.onForegrounded();
      await settle();
      expect(cubit.state.status, AppLockStatus.unlocked);
      expect(vault.vaultKey, isNot(everyElement(0)));
      await cubit.close();
    });

    test('back after 30 s: locked, even if no timer ever ran', () async {
      // Android may freeze the process; the timestamp check covers that.
      final cubit = await unlocked(autoLockAfter: const Duration(hours: 1));
      cubit.onBackgrounded();
      now = now.add(const Duration(hours: 1));
      cubit.onForegrounded();
      await settle();
      expect(cubit.state.status, AppLockStatus.locked);
      expect(vault.vaultKey, everyElement(0));
      await cubit.close();
    });

    test('exactly 30 s counts as expired', () async {
      final cubit = await unlocked();
      cubit.onBackgrounded();
      now = now.add(const Duration(seconds: 30));
      cubit.onForegrounded();
      await settle();
      expect(cubit.state.status, AppLockStatus.locked);
      await cubit.close();
    });

    test('still in the background when the time is up: the timer wipes '
        'the key', () async {
      final cubit = await unlocked(
        autoLockAfter: const Duration(milliseconds: 40),
      );
      cubit.onBackgrounded();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(session.isUnlocked, isFalse);
      expect(vault.vaultKey, everyElement(0));
      expect(cubit.state.status, AppLockStatus.locked);
      await cubit.close();
    });

    test('repeated background events do not restart the countdown', () async {
      final cubit = await unlocked();
      cubit.onBackgrounded();
      now = now.add(const Duration(seconds: 20));
      cubit.onBackgrounded();
      now = now.add(const Duration(seconds: 20));
      cubit.onForegrounded();
      await settle();
      expect(cubit.state.status, AppLockStatus.locked);
      await cubit.close();
    });

    test('a returning app starts a fresh countdown next time', () async {
      final cubit = await unlocked();
      cubit.onBackgrounded();
      now = now.add(const Duration(seconds: 20));
      cubit.onForegrounded();
      cubit.onBackgrounded();
      now = now.add(const Duration(seconds: 20));
      cubit.onForegrounded();
      await settle();
      expect(cubit.state.status, AppLockStatus.unlocked);
      await cubit.close();
    });
  });

  test('eraseDevice locks, erases local keys and returns to setup', () async {
    final cubit = build();
    await cubit.start();
    session.open(vault);
    await settle();

    await cubit.eraseDevice();

    expect(cubit.state.status, AppLockStatus.needsSetup);
    expect(vault.vaultKey, everyElement(0));
    verify(() => store.erase()).called(1);
    await cubit.close();
  });

  test('a new session wipes the keys of the one it replaces', () {
    session.open(vault);
    session.open(
      UnlockedVault(
        deviceId: deviceIdA,
        vaultKey: Uint8List(keySize)..fillRange(0, keySize, 9),
        itemKey: Uint8List(keySize),
        deviceSeed: Uint8List(ed25519SeedSize),
      ),
    );
    expect(vault.vaultKey, everyElement(0));
    expect(session.require.vaultKey, everyElement(9));
  });
}
