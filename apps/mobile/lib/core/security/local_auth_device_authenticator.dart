import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'device_authenticator.dart';

/// [DeviceAuthenticator] on `local_auth` (androidx.biometric).
///
/// `biometricOnly: false` lets the system prompt accept the phone's screen
/// lock (PIN, pattern, password) and any biometric Android offers on top of
/// it. A biometric is never required. [lockStatus] is `secured` when
/// `isDeviceSupported()` says Android can authenticate the user with a
/// biometric or a device credential.
final class LocalAuthDeviceAuthenticator implements DeviceAuthenticator {
  LocalAuthDeviceAuthenticator({LocalAuthentication? localAuth})
    : _auth = localAuth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<DeviceLockStatus> lockStatus() async {
    try {
      return await _auth.isDeviceSupported()
          ? DeviceLockStatus.secured
          : DeviceLockStatus.none;
    } on LocalAuthException {
      return DeviceLockStatus.none;
    } on PlatformException {
      return DeviceLockStatus.none;
    }
  }

  @override
  Future<DeviceAuthOutcome> authenticate({required String reason}) async {
    if (await lockStatus() != DeviceLockStatus.secured) {
      return DeviceAuthOutcome.noScreenLock;
    }
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: false,
      );
      return ok ? DeviceAuthOutcome.success : DeviceAuthOutcome.cancelled;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout => DeviceAuthOutcome.lockedOut,
        LocalAuthExceptionCode.noCredentialsSet =>
          DeviceAuthOutcome.noScreenLock,
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.authInProgress ||
        LocalAuthExceptionCode.userRequestedFallback =>
          DeviceAuthOutcome.cancelled,
        _ => DeviceAuthOutcome.unavailable,
      };
    } on PlatformException {
      return DeviceAuthOutcome.unavailable;
    }
  }
}
