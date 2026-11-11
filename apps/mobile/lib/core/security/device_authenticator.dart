/// Whether this phone has a secure screen lock that can gate the vault.
enum DeviceLockStatus {
  /// A PIN, pattern, password or an enrolled biometric is set up, so Android
  /// can show its own credential prompt. Which of them the user picks is
  /// Android's business; Leopard never requires a biometric.
  secured,

  /// No screen lock at all (or the device cannot report one). The gate is
  /// then the master password.
  none,
}

enum DeviceAuthOutcome {
  success,

  /// The user dismissed the prompt, got the credential wrong or it timed out.
  cancelled,

  /// Too many failed attempts; Android blocks the prompt for a while.
  lockedOut,

  /// The phone has no screen lock, so there is nothing to ask for.
  noScreenLock,

  /// The prompt cannot be shown right now.
  unavailable,
}

abstract interface class DeviceAuthenticator {
  Future<DeviceLockStatus> lockStatus();

  /// Shows the system prompt, which accepts the phone's screen-lock
  /// credential (PIN, pattern, password, or a biometric if Android offers
  /// one). Never throws.
  Future<DeviceAuthOutcome> authenticate({required String reason});
}
