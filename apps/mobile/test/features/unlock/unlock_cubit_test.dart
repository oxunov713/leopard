import 'package:bloc_test/bloc_test.dart';
import 'package:leopard_mobile/core/error/failures.dart';
import 'package:leopard_mobile/core/security/biometric_authenticator.dart';
import 'package:leopard_mobile/features/unlock/presentation/unlock_cubit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  late MockUnlockRepository repository;

  setUp(() {
    repository = MockUnlockRepository();
    when(
      () => repository.biometricAvailability(),
    ).thenAnswer((_) async => BiometricAvailability.available);
  });

  UnlockCubit build() => UnlockCubit(repository);

  const available = BiometricAvailability.available;

  group('on app open', () {
    blocTest<UnlockCubit, UnlockState>(
      'asks for the biometric at once and unlocks',
      build: build,
      setUp: () => when(
        () => repository.unlockWithBiometrics(),
      ).thenAnswer((_) async => BiometricOutcome.success),
      act: (cubit) => cubit.start(),
      expect: () => const [
        UnlockState(biometrics: available),
        UnlockState(status: UnlockStatus.authenticating, biometrics: available),
        UnlockState(status: UnlockStatus.unlocked, biometrics: available),
      ],
      verify: (_) {
        verify(() => repository.unlockWithBiometrics()).called(1);
        verifyNever(() => repository.unlockWithMasterPassword(any()));
      },
    );

    blocTest<UnlockCubit, UnlockState>(
      'without a strong biometric only the master password is offered',
      build: build,
      setUp: () => when(
        () => repository.biometricAvailability(),
      ).thenAnswer((_) async => BiometricAvailability.notEnrolled),
      act: (cubit) => cubit.start(),
      expect: () => const [
        UnlockState(biometrics: BiometricAvailability.notEnrolled),
      ],
      verify: (cubit) {
        expect(cubit.state.canUseBiometrics, isFalse);
        verifyNever(() => repository.unlockWithBiometrics());
      },
    );

    test('start runs once even if the screen asks twice', () async {
      when(
        () => repository.unlockWithBiometrics(),
      ).thenAnswer((_) async => BiometricOutcome.cancelled);
      final cubit = build();
      await cubit.start();
      await cubit.start();
      verify(() => repository.unlockWithBiometrics()).called(1);
      await cubit.close();
    });
  });

  group('biometric outcomes', () {
    blocTest<UnlockCubit, UnlockState>(
      'cancelled: stays locked, can retry',
      build: build,
      seed: () => const UnlockState(biometrics: available),
      setUp: () => when(
        () => repository.unlockWithBiometrics(),
      ).thenAnswer((_) async => BiometricOutcome.cancelled),
      act: (cubit) => cubit.unlockWithBiometrics(),
      expect: () => const [
        UnlockState(status: UnlockStatus.authenticating, biometrics: available),
        UnlockState(biometrics: available),
      ],
    );

    test('locked out: points to the master password', () async {
      when(
        () => repository.unlockWithBiometrics(),
      ).thenAnswer((_) async => BiometricOutcome.lockedOut);
      final cubit = build();
      await cubit.unlockWithBiometrics();
      expect(cubit.state.status, UnlockStatus.idle);
      expect(cubit.state.message, contains('master password'));
      await cubit.close();
    });

    test('a storage error is reported, not thrown', () async {
      when(
        () => repository.unlockWithBiometrics(),
      ).thenThrow(const StorageFailure());
      final cubit = build();
      await cubit.unlockWithBiometrics();
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
