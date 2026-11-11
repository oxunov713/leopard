import '../../../core/security/device_authenticator.dart';

abstract interface class UnlockRepository {
  Future<DeviceLockStatus> deviceLockStatus();

  /// Shows the system screen-lock prompt (PIN, pattern, password or any
  /// biometric Android offers) and, on success, loads the keys from the
  /// Keystore-backed store into memory.
  Future<DeviceAuthOutcome> unlockWithDeviceCredential();

  /// Proves knowledge of the master password offline by unwrapping the vault
  /// key with it (Argon2id in a background isolate). This is the only way in
  /// on a phone without a screen lock, and an explicit option on every phone.
  ///
  /// Returns `false` when the password is wrong.
  Future<bool> unlockWithMasterPassword(String masterPassword);
}
