import 'package:bloc_test/bloc_test.dart';
import 'package:leopard_mobile/core/error/failures.dart';
import 'package:leopard_mobile/core/security/device_authenticator.dart';
import 'package:leopard_mobile/features/unlock/presentation/unlock_cubit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  late MockUnlockRepository repository;

  setUp(() {
    repository = MockUnlockRepository();
    when(
      () => repository.deviceLockStatus(),
    ).thenAnswer((_) async => DeviceLockStatus.secured);
  });

  UnlockCubit build() => UnlockCubit(repository);

  const available = DeviceLockStatus.secured;
  const noLock = DeviceLockStatus.none;

  group('on app open', () {
    blocTest<UnlockCubit, UnlockState>(
      'asks for the screen lock at once and unlocks',
      build: build,
      setUp: () => when(
        () => repository.unlockWithDeviceCredential(),
      ).thenAnswer((_) async => DeviceAuthOutcome.success),
      act: (cubit) => cubit.start(),
      expect: () => const [
        UnlockState(deviceLock: available),
        UnlockState(status: UnlockStatus.authenticating, deviceLock: available),
        UnlockState(status: UnlockStatus.unlocked, deviceLock: available),
      ],
      verify: (_) {
        verify(() => repository.unlockWithDeviceCredential()).called(1);
        verifyNever(() => repository.unlockWithMasterPassword(any()));
      },
    );

    blocTest<UnlockCubit, UnlockState>(
      'without a screen lock only the master password is offered',
      build: build,
      setUp: () => when(
        () => repository.deviceLockStatus(),
      ).thenAnswer((_) async => DeviceLockStatus.none),
      act: (cubit) => cubit.start(),
      expect: () => const [UnlockState(deviceLock: noLock)],
      verify: (cubit) {
        expect(cubit.state.canUseDeviceLock, isFalse);
        expect(cubit.state.hasNoScreenLock, isTrue);
        verifyNever(() => repository.unlockWithDeviceCredential());
      },
    );

    test('start runs once even if the screen asks twice', () async {
      when(
        () => repository.unlockWithDeviceCredential(),
      ).thenAnswer((_) async => DeviceAuthOutcome.cancelled);
      final cubit = build();
      await cubit.start();
      await cubit.start();
      verify(() => repository.unlockWithDeviceCredential()).called(1);
      await cubit.close();
    });
  });

  group('device credential outcomes', () {
    blocTest<UnlockCubit, UnlockState>(
      'cancelled: stays locked, can retry',
      build: build,
      seed: () => const UnlockState(deviceLock: available),
      setUp: () => when(
        () => repository.unlockWithDeviceCredential(),
      ).thenAnswer((_) async => DeviceAuthOutcome.cancelled),
      act: (cubit) => cubit.unlockWithDeviceCredential(),
      expect: () => const [
        UnlockState(status: UnlockStatus.authenticating, deviceLock: available),
        UnlockState(deviceLock: available),
      ],
    );

    test('failed or refused credential: stays locked, no message', () async {
      // Android reports a wrong PIN / pattern as a failed (false) result.
      when(
        () => repository.unlockWithDeviceCredential(),
      ).thenAnswer((_) async => DeviceAuthOutcome.cancelled);
      final cubit = build();
      await cubit.unlockWithDeviceCredential();
      expect(cubit.state.status, UnlockStatus.idle);
      expect(cubit.state.message, isNull);
      verifyNever(() => repository.unlockWithMasterPassword(any()));
      await cubit.close();
    });

    test('the phone lost its screen lock: switches to the password', () async {
      when(
        () => repository.unlockWithDeviceCredential(),
      ).thenAnswer((_) async => DeviceAuthOutcome.noScreenLock);
      final cubit = build();
      await cubit.unlockWithDeviceCredential();
      expect(cubit.state.status, UnlockStatus.idle);
      expect(cubit.state.hasNoScreenLock, isTrue);
      expect(cubit.state.message, contains('no screen lock'));
      await cubit.close();
    });

    test('unavailable: points to the master password', () async {
      when(
        () => repository.unlockWithDeviceCredential(),
      ).thenAnswer((_) async => DeviceAuthOutcome.unavailable);
      final cubit = build();
      await cubit.unlockWithDeviceCredential();
      expect(cubit.state.message, contains('master password'));
      await cubit.close();
    });

    test('locked out: points to the master password', () async {
      when(
        () => repository.unlockWithDeviceCredential(),
      ).thenAnswer((_) async => DeviceAuthOutcome.lockedOut);
      final cubit = build();
      await cubit.unlockWithDeviceCredential();
      expect(cubit.state.status, UnlockStatus.idle);
      expect(cubit.state.message, contains('master password'));
      await cubit.close();
    });

    test('a storage error is reported, not thrown', () async {
      when(
        () => repository.unlockWithDeviceCredential(),
      ).thenThrow(const StorageFailure());
      final cubit = build();
      await cubit.unlockWithDeviceCredential();
      expect(cubit.state.status, UnlockStatus.idle);
      expect(
        cubit.state.message,
        'Secure storage on this device is unavailable.',
      );
      await cubit.close();
    });
  });

  group('master password fallback', () {
    blocTest<UnlockCubit, UnlockState>(
      'correct password unlocks',
      build: build,
      setUp: () => when(
        () => repository.unlockWithMasterPassword('right'),
      ).thenAnswer((_) async => true),
      act: (cubit) => cubit.unlockWithMasterPassword('right'),
      expect: () => const [
        UnlockState(status: UnlockStatus.deriving),
        UnlockState(status: UnlockStatus.unlocked),
      ],
    );

    blocTest<UnlockCubit, UnlockState>(
      'wrong password: message and attempt counter',
      build: build,
      setUp: () => when(
        () => repository.unlockWithMasterPassword(any()),
      ).thenAnswer((_) async => false),
      act: (cubit) async {
        await cubit.unlockWithMasterPassword('wrong');
        await cubit.unlockWithMasterPassword('wrong again');
      },
      expect: () => const [
        UnlockState(status: UnlockStatus.deriving),
        UnlockState(
          message: 'Wrong master password.',
          failedPasswordAttempts: 1,
        ),
        UnlockState(status: UnlockStatus.deriving, failedPasswordAttempts: 1),
        UnlockState(
          message: 'Wrong master password.',
          failedPasswordAttempts: 2,
        ),
      ],
    );

    test('an empty password never reaches the KDF', () async {
      final cubit = build();
      await cubit.unlockWithMasterPassword('');
      expect(cubit.state.message, 'Enter your master password.');
      verifyNever(() => repository.unlockWithMasterPassword(any()));
      await cubit.close();
    });

    test('one derivation at a time', () async {
      when(() => repository.unlockWithMasterPassword(any())).thenAnswer((
        _,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return false;
      });
      final cubit = build();
      final first = cubit.unlockWithMasterPassword('a');
      await cubit.unlockWithMasterPassword('b'); // ignored: busy
      await first;
      verify(() => repository.unlockWithMasterPassword(any())).called(1);
      await cubit.close();
    });
  });
}
