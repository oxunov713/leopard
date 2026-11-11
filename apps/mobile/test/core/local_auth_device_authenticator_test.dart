import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_mobile/core/security/device_authenticator.dart';
import 'package:leopard_mobile/core/security/local_auth_device_authenticator.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';

class MockLocalAuthentication extends Mock implements LocalAuthentication {}

void main() {
  late MockLocalAuthentication auth;
  late LocalAuthDeviceAuthenticator authenticator;

  setUp(() {
    auth = MockLocalAuthentication();
    authenticator = LocalAuthDeviceAuthenticator(localAuth: auth);
    when(auth.isDeviceSupported).thenAnswer((_) async => true);
  });

  When<Future<bool>> authenticateCall() => when(
    () => auth.authenticate(
      localizedReason: any(named: 'localizedReason'),
      biometricOnly: any(named: 'biometricOnly'),
      sensitiveTransaction: any(named: 'sensitiveTransaction'),
      persistAcrossBackgrounding: any(named: 'persistAcrossBackgrounding'),
    ),
  );

  group('lockStatus', () {
    test('a phone with a screen lock is secured', () async {
      expect(await authenticator.lockStatus(), DeviceLockStatus.secured);
    });

    test('a phone without one is not', () async {
      when(auth.isDeviceSupported).thenAnswer((_) async => false);
      expect(await authenticator.lockStatus(), DeviceLockStatus.none);
    });

    test('a plugin error counts as no screen lock', () async {
      when(auth.isDeviceSupported).thenThrow(PlatformException(code: 'x'));
      expect(await authenticator.lockStatus(), DeviceLockStatus.none);
    });
  });

  group('authenticate', () {
    test('accepts the device credential: biometricOnly is false', () async {
      authenticateCall().thenAnswer((_) async => true);

      expect(
        await authenticator.authenticate(reason: 'Unlock'),
        DeviceAuthOutcome.success,
      );
      verify(
        () => auth.authenticate(
          localizedReason: 'Unlock',
          biometricOnly: false,
          sensitiveTransaction: true,
          persistAcrossBackgrounding: false,
        ),
      ).called(1);
    });

    test('a failed attempt is a cancel, not a success', () async {
      authenticateCall().thenAnswer((_) async => false);
      expect(
        await authenticator.authenticate(reason: 'Unlock'),
        DeviceAuthOutcome.cancelled,
      );
    });

    test('without a screen lock the prompt is never shown', () async {
      when(auth.isDeviceSupported).thenAnswer((_) async => false);
      expect(
        await authenticator.authenticate(reason: 'Unlock'),
        DeviceAuthOutcome.noScreenLock,
      );
      verifyNever(
        () => auth.authenticate(
          localizedReason: any(named: 'localizedReason'),
          biometricOnly: any(named: 'biometricOnly'),
          sensitiveTransaction: any(named: 'sensitiveTransaction'),
          persistAcrossBackgrounding: any(named: 'persistAcrossBackgrounding'),
        ),
      );
    });

    test('exception codes map to outcomes', () async {
      final expected = {
        LocalAuthExceptionCode.userCanceled: DeviceAuthOutcome.cancelled,
        LocalAuthExceptionCode.timeout: DeviceAuthOutcome.cancelled,
        LocalAuthExceptionCode.systemCanceled: DeviceAuthOutcome.cancelled,
        LocalAuthExceptionCode.userRequestedFallback:
            DeviceAuthOutcome.cancelled,
        LocalAuthExceptionCode.temporaryLockout: DeviceAuthOutcome.lockedOut,
        LocalAuthExceptionCode.biometricLockout: DeviceAuthOutcome.lockedOut,
        LocalAuthExceptionCode.noCredentialsSet: DeviceAuthOutcome.noScreenLock,
        LocalAuthExceptionCode.uiUnavailable: DeviceAuthOutcome.unavailable,
      };
      for (final entry in expected.entries) {
        authenticateCall().thenThrow(LocalAuthException(code: entry.key));
        expect(
          await authenticator.authenticate(reason: 'Unlock'),
          entry.value,
          reason: entry.key.name,
        );
      }
    });

    test('a platform error is unavailable, never thrown', () async {
      authenticateCall().thenThrow(PlatformException(code: 'boom'));
      expect(
        await authenticator.authenticate(reason: 'Unlock'),
        DeviceAuthOutcome.unavailable,
      );
    });
  });
}
