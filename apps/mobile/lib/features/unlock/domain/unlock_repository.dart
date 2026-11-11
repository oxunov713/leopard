import '../../../core/security/biometric_authenticator.dart';

abstract interface class UnlockRepository {
  Future<BiometricAvailability> biometricAvailability();

  /// Shows the biometric prompt and, on success, loads the keys from the
  /// Keystore-backed store into memory.
  Future<BiometricOutcome> unlockWithBiometrics();

  /// Fallback: proves knowledge of the master password offline by unwrapping
  /// the vault key with it (Argon2id in a background isolate).
  ///
  /// Returns `false` when the password is wrong.
  Future<bool> unlockWithMasterPassword(String masterPassword);
}
