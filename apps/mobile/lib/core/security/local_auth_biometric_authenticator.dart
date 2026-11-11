import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'biometric_authenticator.dart';

/// [BiometricAuthenticator] on `local_auth` (androidx.biometric).
///
/// Only biometrics count: `biometricOnly` removes the PIN / pattern fallback
/// from the prompt, and [availability] reports [BiometricAvailability.available]
/// only when Android says a Class 3 (BIOMETRIC_STRONG) biometric is enrolled.
final class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  LocalAuthBiometricAuthenticator({LocalAuthentication? localAuth})
    : _auth = localAuth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<BiometricAvailability> availability() async {
    try {
      if (!await _auth.isDeviceSupported() || !await _auth.canCheckBiometrics) {
        return BiometricAvailability.unsupported;
      }
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.contains(BiometricType.strong)
          ? BiometricAvailability.available
          : BiometricAvailability.notEnrolled;
    } on LocalAuthException {
      return BiometricAvailability.unsupported;
    } on PlatformException {
      return BiometricAvailability.unsupported;
    }
  }

  @override
  Future<BiometricOutcome> authenticate({required String reason}) async {
    if (await availability() != BiometricAvailability.available) {
      return BiometricOutcome.unavailable;
    }
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: false,
      );
      return ok ? BiometricOutcome.success : BiometricOutcome.cancelled;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout => BiometricOutcome.lockedOut,
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.authInProgress ||
        LocalAuthExceptionCode.userRequestedFallback =>
          BiometricOutcome.cancelled,
        _ => BiometricOutcome.unavailable,
      };
    } on PlatformException {
      return BiometricOutcome.unavailable;
    }
  }
}
