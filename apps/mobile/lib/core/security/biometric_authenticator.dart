/// Whether this phone can gate the vault with biometrics.
enum BiometricAvailability {
  /// A Class 3 ("strong") biometric is enrolled.
  available,

  /// The hardware exists but no strong biometric is enrolled.
  notEnrolled,

  /// No usable biometric hardware.
  unsupported,
}

enum BiometricOutcome {
  success,

  /// The user dismissed the prompt or it timed out.
  cancelled,

  /// Too many failed attempts; the sensor is locked for a while.
  lockedOut,

  /// Biometrics cannot be used right now.
  unavailable,
}

abstract interface class BiometricAuthenticator {
  Future<BiometricAvailability> availability();

  /// Shows the system biometric prompt. Never throws.
  Future<BiometricOutcome> authenticate({required String reason});
}
