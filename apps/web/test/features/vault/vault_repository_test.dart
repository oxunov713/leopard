// VaultRepositoryImpl against an in-memory server that enforces the version
// rules of docs/api.md, with the real crypto of leopard_core.
import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/core/error/failures.dart';
import 'package:leopard_web/core/session/vault_session.dart';
import 'package:leopard_web/features/vault/data/vault_repository_impl.dart';
import 'package:leopard_web/features/vault/domain/vault_repository.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  final crypto = LeopardCrypto();
  late FakeItemServer server;
  late VaultSession session;
  late VaultRepositoryImpl repository;

  setUp(() async {
    server = FakeItemServer();
    session = await unlockedSession(crypto);
    repository = VaultRepositoryImpl(
      api: server,
      session: session,
      crypto: crypto,
    );
  });

  /// Encrypts [item] the way another device with the same vault key would.
  Future<SealedItem> sealAs(String id, int version, VaultItem item) =>
      crypto.encryptItem(
        itemKey: session.require.itemKey,
        itemId: id,
        version: version,
        plaintext: item.encode(),
      );

  test('create uploads ciphertext only, and sync decrypts it again', () async {
    final created = await repository.create(login('Example'));

    expect(created.version, 1);
    expect(isCanonicalUuid(created.id), isTrue);
    final stored = server.items[created.id]!;
    final secret = 'correct horse battery staple'.codeUnits;
    expect(
      _contains(stored.ciphertext!, Uint8List.fromList(secret)),
      isFalse,
      reason: 'the password must not appear in what the server stores',
    );

    final delta = await repository.sync();
    expect(delta.upserts, hasLength(1));
    final item = delta.upserts.single.item as LoginItem;
    expect(item.title, 'Example');
    expect(item.password, 'correct horse battery staple');
    expect(delta.deletedIds, isEmpty);
    expect(delta.unreadableIds, isEmpty);
  });

  test('update writes version + 1 with expected_version', () async {
    final created = await repository.create(login('Example'));
    final updated = await repository.update(
      id: created.id,
      baseVersion: created.version,
      item: login('Example', password: 'new password'),
    );
    expect(updated.version, 2);

    final delta = await repository.sync();
    expect((delta.upserts.single.item as LoginItem).password, 'new password');
    expect(delta.upserts.single.version, 2);
  });

  test('incremental sync returns only what changed, with tombstones', () async {
    final a = await repository.create(login('A'));
    final first = await repository.sync();
    final b = await repository.create(login('B'));
    await repository.delete(id: a.id, baseVersion: a.version);

    final delta = await repository.sync(since: first.serverTime);
    expect(delta.upserts.map((e) => e.id), [b.id]);
    expect(delta.deletedIds, {a.id});
  });

  group('409 version_conflict', () {
    test('a stale update reports the server copy, decrypted', () async {
      final created = await repository.create(login('Mine'));
      // Another device saves version 2.
      server.writeDirectly(
        created.id,
        await sealAs(created.id, 2, login('Theirs', password: 'theirs')),
        2,
      );

      await expectLater(
        repository.update(
          id: created.id,
          baseVersion: created.version,
          item: login('Mine', password: 'mine'),
        ),
        throwsA(
          isA<VaultConflict>()
              .having((c) => c.id, 'id', created.id)
              .having((c) => c.serverVersion, 'serverVersion', 2)
              .having((c) => c.server?.item.title, 'server title', 'Theirs'),
        ),
      );
      // Nothing was overwritten.
      final delta = await repository.sync();
      expect((delta.upserts.single.item as LoginItem).password, 'theirs');
    });

    test('keep mine: retrying at the server version wins', () async {
      final created = await repository.create(login('Mine'));
      server.writeDirectly(
        created.id,
        await sealAs(created.id, 2, login('Theirs')),
        2,
      );
      final mine = login('Mine', password: 'mine');
      final conflict =
          await repository
                  .update(id: created.id, baseVersion: 1, item: mine)
                  .then<Object?>((_) => null, onError: (Object e) => e)
              as VaultConflict;

      final saved = await repository.update(
        id: created.id,
        baseVersion: conflict.serverVersion,
        item: mine,
      );
      expect(saved.version, 3);
      final delta = await repository.sync();
      expect(delta.upserts.single.version, 3);
      expect((delta.upserts.single.item as LoginItem).password, 'mine');
    });

    test('a stale delete is a conflict, not a deletion', () async {
      final created = await repository.create(login('Mine'));
      server.writeDirectly(
        created.id,
        await sealAs(created.id, 2, login('Theirs')),
        2,
      );
      await expectLater(
        repository.delete(id: created.id, baseVersion: 1),
        throwsA(isA<VaultConflict>()),
      );
      expect(server.items[created.id]!.deleted, isFalse);

      // "Delete anyway" at the server's version.
      await repository.delete(id: created.id, baseVersion: 2);
      expect(server.items[created.id]!.deleted, isTrue);
    });
  });

  group('410 item_deleted', () {
    test('updating an item deleted elsewhere', () async {
      final created = await repository.create(login('Gone'));
      server.deleteDirectly(created.id);

      await expectLater(
        repository.update(
          id: created.id,
          baseVersion: created.version,
          item: login('Gone', password: 'x'),
        ),
        throwsA(
          isA<ItemDeletedRemotely>().having((e) => e.id, 'id', created.id),
        ),
      );
    });

    test('deleting an item that is already gone succeeds', () async {
      final created = await repository.create(login('Gone'));
      server.deleteDirectly(created.id);
      await repository.delete(id: created.id, baseVersion: created.version);
    });
  });

  group('items that cannot be trusted are not shown', () {
    test('tampered ciphertext', () async {
      final created = await repository.create(login('Example'));
      final stored = server.items[created.id]!;
      final tampered = Uint8List.fromList(stored.ciphertext!)..[0] ^= 0x01;
      server.items[created.id] = RemoteItem(
        id: stored.id,
        version: stored.version,
        updatedAt: stored.updatedAt,
        deleted: false,
        ciphertext: tampered,
        nonce: stored.nonce,
      );

      final delta = await repository.sync();
      expect(delta.upserts, isEmpty);
      expect(delta.unreadableIds, {created.id});
    });

    test('old ciphertext replayed under a newer version number', () async {
      final created = await repository.create(login('Example'));
      final stored = server.items[created.id]!;
      server.items[created.id] = RemoteItem(
        id: stored.id,
        version: 5, // the server lies about the version
        updatedAt: stored.updatedAt,
        deleted: false,
        ciphertext: stored.ciphertext,
        nonce: stored.nonce,
      );
      final delta = await repository.sync();
      expect(delta.unreadableIds, {created.id});
    });

    test("one item's ciphertext served as another item", () async {
      final a = await repository.create(login('A'));
      final stored = server.items[a.id]!;
      server.items[itemIdB] = RemoteItem(
        id: itemIdB,
        version: stored.version,
        updatedAt: stored.updatedAt,
        deleted: false,
        ciphertext: stored.ciphertext,
        nonce: stored.nonce,
      );
      final delta = await repository.sync();
      expect(delta.upserts.map((e) => e.id), [a.id]);
      expect(delta.unreadableIds, {itemIdB});
    });
  });

  test('an item from a newer schema is kept verbatim and read-only', () async {
    final raw = <String, Object?>{'v': 2, 'type': 'passkey', 'title': 'Future'};
    server.writeDirectly(
      itemIdC,
      await sealAs(itemIdC, 1, UnknownItem(raw)),
      1,
    );

    final delta = await repository.sync();
    final found = delta.upserts.single;
    expect(found.item, isA<UnknownItem>());
    expect(found.editable, isFalse);
    expect(found.item.toJson(), raw);
  });

  test('a 401 is announced so that the app can lock', () async {
    await repository.create(login('Example'));
    final ended = <UnauthorizedException>[];
    final subscription = server.sessionEnded.listen(ended.add);
    server.revokedWith = 'session_revoked';

    await expectLater(
      repository.sync(),
      throwsA(isA<UnauthorizedException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(ended.single.sessionEnded, isTrue);
    await subscription.cancel();
  });

  test('nothing works while the vault is locked', () async {
    final created = await repository.create(login('Example'));
    session.close();

    await expectLater(
      repository.create(login('Other')),
      throwsA(isA<VaultLockedFailure>()),
    );
    // The ciphertext is still fetched, but cannot be opened.
    await expectLater(repository.sync(), throwsA(isA<VaultLockedFailure>()));
    expect(server.items.keys, [created.id]);
  });
}

bool _contains(Uint8List haystack, Uint8List needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; match && j < needle.length; j++) {
      match = haystack[i + j] == needle[j];
    }
    if (match) return true;
  }
  return false;
}
