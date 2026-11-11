import 'dart:async';
import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

import '../error/failures.dart';

/// The secrets that exist in memory while the vault is unlocked.
final class UnlockedVault {
  UnlockedVault({
    required this.deviceId,
    required this.vaultKey,
    required this.itemKey,
    required this.deviceSeed,
  });

  final String deviceId;
  final Uint8List vaultKey;
  final Uint8List itemKey;
  final Uint8List deviceSeed;

  void destroy() => wipeAll([vaultKey, itemKey, deviceSeed]);
}

/// Holds the [UnlockedVault], or nothing while locked.
///
/// This is the only long-lived reference to the vault key. [close] zeroes
/// the key bytes; everything else must fetch them through [require] each
/// time and never keep its own copy.
final class VaultSession {
  UnlockedVault? _current;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  bool get isUnlocked => _current != null;

  /// Emits `true` after [open] and `false` after [close].
  Stream<bool> get changes => _changes.stream;

  /// Throws [VaultLockedFailure] while locked.
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
