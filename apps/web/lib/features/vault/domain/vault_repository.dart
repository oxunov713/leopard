import 'package:leopard_core/leopard_core.dart';

import 'vault_entry.dart';

/// What one `GET /v1/items` call changed.
final class SyncDelta {
  const SyncDelta({
    required this.upserts,
    required this.deletedIds,
    required this.unreadableIds,
    required this.serverTime,
  });

  /// New or changed items, decrypted.
  final List<VaultEntry> upserts;

  /// Items deleted on the server (tombstones).
  final Set<String> deletedIds;

  /// Items that failed authentication or do not parse. Their ciphertext is
  /// left alone on the server.
  final Set<String> unreadableIds;

  /// Opaque cursor: pass as `since` to the next sync.
  final String serverTime;
}

/// The server holds a different version than the one the edit started from
/// (`409 version_conflict`).
final class VaultConflict implements Exception {
  const VaultConflict({
    required this.id,
    required this.serverVersion,
    this.server,
  });

  final String id;
  final int serverVersion;

  /// The server's copy, when it could be fetched and decrypted.
  final VaultEntry? server;
}

/// The item no longer exists on the server (`410 item_deleted` or a
/// tombstone found while resolving a conflict).
final class ItemDeletedRemotely implements Exception {
  const ItemDeletedRemotely(this.id);

  final String id;
}

abstract interface class VaultRepository {
  /// Fetches items changed since [since] (everything when `null`).
  Future<SyncDelta> sync({String? since});

  /// Encrypts and uploads a new item.
  Future<VaultEntry> create(VaultItem item);

  /// Replaces item [id], which the caller last saw at [baseVersion].
  ///
  /// Throws [VaultConflict] or [ItemDeletedRemotely].
  Future<VaultEntry> update({
    required String id,
    required int baseVersion,
    required VaultItem item,
  });

  /// Deletes item [id]. An item that is already gone counts as deleted.
  ///
  /// Throws [VaultConflict].
  Future<void> delete({required String id, required int baseVersion});
}
