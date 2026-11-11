/// Carries a generated password from the generator to the "new item" form.
///
/// It is a field in memory, read once. The password is deliberately not
/// passed as route data: on the web, route state can be written to the
/// browser's session history, which may be persisted to disk.
final class PasswordHandoff {
  String? _password;

  /// Stores [password] for the next [take].
  void offer(String password) => _password = password;

  /// Returns the stored password, once.
  String? take() {
    final password = _password;
    _password = null;
    return password;
  }

  /// Forgets the stored password (on lock).
  void clear() => _password = null;
}
