/// Copies secrets to the clipboard and removes them again.
abstract interface class SecretClipboard {
  /// Puts [secret] on the clipboard and schedules its removal.
  Future<void> copy(String secret);

  /// Clears the clipboard now if this app put a secret there.
  Future<void> clearNow();
}
