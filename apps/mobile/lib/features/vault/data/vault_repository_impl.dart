import 'package:leopard_core/leopard_core.dart';

import '../../../core/network/remote_vault.dart';
import '../../../core/session/vault_session.dart';
import '../domain/vault_entry.dart';
import '../domain/vault_repository.dart';

/// [VaultRepository] that encrypts on the phone and stores on the server.
///
/// Nothing is cached on disk: decrypted items live in memory only, and the
/// vault is fetched again after every unlock.
final class VaultRepositoryImpl implements VaultRepository {
  VaultRepositoryImpl({
    required RemoteVault remote,
    required VaultSession session,
    required LeopardCrypto crypto,
  }) : _remote = remote,
       _session = session,
       _crypto = crypto;

  final RemoteVault _remote;
  final VaultSession _session;
  final LeopardCrypto _crypto;

  @override
  Future<SyncDelta> sync({String? since}) async {
    final page = await _remote.listItems(since: since);
    final upserts = <VaultEntry>[];
    final deleted = <String>{};
    final unreadable = <String>{};
    for (final remote in page.items) {
      if (remote.deleted) {
        deleted.add(remote.id);
        continue;
      }
      final entry = await _decrypt(remote);
      if (entry == null) {
        unreadable.add(remote.id);
      } else {
        upserts.add(entry);
      }
    }
    return SyncDelta(
      upserts: upserts,
      deletedIds: deleted,
      unreadableIds: unreadable,
      serverTime: page.serverTime,
    );
  }

  @override
  Future<VaultEntry> create(VaultItem item) async {
    final id = newUuid();
    final meta = await _put(id: id, baseVersion: 0, item: item);
    return VaultEntry(id: id, version: meta.version, item: item);
  }

  @override
  Future<VaultEntry> update({
    required String id,
    required int baseVersion,
    required VaultItem item,
  }) async {
    try {
      final meta = await _put(id: id, baseVersion: baseVersion, item: item);
      return VaultEntry(id: id, version: meta.version, item: item);
    } on ConflictException catch (e) {
      throw await _conflict(id, e.serverVersion);
    } on GoneException {
      throw ItemDeletedRemotely(id);
    } on NotFoundException {
      throw ItemDeletedRemotely(id);
    }
  }

  @override
  Future<void> delete({required String id, required int baseVersion}) async {
    try {
      await _remote.deleteItem(id: id, expectedVersion: baseVersion);
    } on ConflictException catch (e) {
      final conflict = await _conflict(id, e.serverVersion);
      if (conflict is ItemDeletedRemotely) {
        return;
      }
      throw conflict;
    } on GoneException {
      return;
    } on NotFoundException {
      return;
    }
  }

  /// Encrypts [item] for version `baseVersion + 1`: the version it will have
  /// after the write is part of the authenticated data (crypto-spec §4).
  Future<ItemMeta> _put({
    required String id,
    required int baseVersion,
    required VaultItem item,
  }) async {
    final sealed = await _crypto.encryptItem(
      itemKey: _session.require.itemKey,
      itemId: id,
      version: baseVersion + 1,
      plaintext: item.encode(),
    );
    return _remote.putItem(
      id: id,
      sealed: sealed,
      expectedVersion: baseVersion,
    );
  }

  /// Looks up what the server holds for [id] after a 409.
  Future<Exception> _conflict(String id, int? reportedVersion) async {
    final page = await _remote.listItems();
    RemoteItem? current;
    for (final remote in page.items) {
      if (remote.id == id) {
        current = remote;
        break;
      }
    }
    if (current == null) {
      return VaultConflict(id: id, serverVersion: reportedVersion ?? 0);
    }
    if (current.deleted) {
      return ItemDeletedRemotely(id);
    }
    return VaultConflict(
      id: id,
      serverVersion: current.version,
      server: await _decrypt(current),
    );
  }

  Future<VaultEntry?> _decrypt(RemoteItem remote) async {
    final nonce = remote.nonce;
    final ciphertext = remote.ciphertext;
    if (nonce == null || ciphertext == null) {
      return null;
    }
    try {
      final plaintext = await _crypto.openItem(
        itemKey: _session.require.itemKey,
        nonce: nonce,
        itemId: remote.id,
        version: remote.version,
        ciphertext: ciphertext,
      );
      return VaultEntry(
        id: remote.id,
        version: remote.version,
        item: VaultItem.decode(plaintext),
      );
    } on LeopardCryptoException {
      return null;
    } on ItemFormatException {
      return null;
    }
  }
}
