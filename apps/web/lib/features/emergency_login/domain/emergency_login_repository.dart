/// The steps of an emergency login, for the progress display.
enum EmergencyLoginPhase {
  /// `GET /v1/auth/master/params`.
  fetchingParameters,

  /// Argon2id. The slow step.
  derivingKey,

  /// `POST /v1/auth/master/login` and unwrapping the vault key.
  verifying,
}

abstract interface class EmergencyLoginRepository {
  /// Logs in with the master password and a TOTP code (crypto-spec §5 to
  /// §7): derives the KEK, proves knowledge of it without sending it,
  /// receives `wrapped_vk_master` and unwraps the vault key in the browser.
  ///
  /// Throws `ValidationFailure`, an `ApiException`, or
  /// `ServerMismatchFailure` if the server accepted the proof but its
  /// wrapped key does not open.
  Future<void> login({
    required String masterPassword,
    required String totpCode,
    void Function(EmergencyLoginPhase phase)? onPhase,
  });
}
