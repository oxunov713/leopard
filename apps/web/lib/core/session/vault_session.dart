import 'dart:async';
import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

import '../error/failures.dart';

/// How the browser obtained the vault key.
enum LoginMethod {
  /// Approved on the phone (crypto-spec §10).
  qr,

  /// Master password and TOTP code (crypto-spec §5 to §7).
  emergency,
}

/// The secrets that exist in memory while the browser is signed in.
final class UnlockedVault {
  UnlockedVault({
    required this.vaultKey,
    required this.itemKey,
    required this.sessionId,
    required this.method,
    required this.idleTimeout,
  });

  final Uint8List vaultKey;
  final Uint8List itemKey;

  /// The server's id of the web session. Not a secret.
  final String sessionId;
  final LoginMethod method;

  /// The idle limit the server announced for this session (300 s).
  final Duration idleTimeout;

  void destroy() => wipeAll([vaultKey, itemKey]);
}

/// Holds the [UnlockedVault], or nothing while signed out.
///
/// This is the only long-lived reference to the vault key, and it is a plain
/// object in memory: nothing here, or anywhere else in the web app, writes
/// to `localStorage`, `sessionStorage`, IndexedDB or a cookie. [close] zeroes
/// the key bytes; everything else fetches them through [require] each time
/// and never keeps its own copy. The session token lives next to it, inside
/// the API client, under the same rule.
final class VaultSession {
  UnlockedVault? _current;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  bool get isUnlocked => _current != null;

  /// The current vault, or `null` while signed out.
  UnlockedVault? get current => _current;

  /// Emits `true` after [open] and `false` after [close].
  Stream<bool> get changes => _changes.stream;

  /// Throws [VaultLockedFailure] while signed out.
  UnlockedVault get require => _current ?? (throw const VaultLockedFailure());

  void open(UnlockedVault vault) {
    _current?.destroy();
    _current = vault;
    _changes.add(true);
  }

  void close() {
    final current = _current;
    if (current == null) {
      return;
    }
    _current = null;
    current.destroy();
    _changes.add(false);
  }

  Future<void> dispose() async {
    close();
    await _changes.close();
  }
}
