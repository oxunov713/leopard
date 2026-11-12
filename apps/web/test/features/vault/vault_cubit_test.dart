import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/features/vault/domain/vault_entry.dart';
import 'package:leopard_web/features/vault/domain/vault_repository.dart';
import 'package:leopard_web/features/vault/presentation/vault_cubit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

SyncDelta delta({
  List<VaultEntry> upserts = const [],
  Set<String> deleted = const {},
  Set<String> unreadable = const {},
  String serverTime = '2026-11-11T10:00:10Z',
}) => SyncDelta(
  upserts: upserts,
  deletedIds: deleted,
  unreadableIds: unreadable,
  serverTime: serverTime,
);

void main() {
  late MockVaultRepository repository;
  final alpha = entry(itemIdA, login('Alpha', username: 'aziz@example.com'));
  final bravo = entry(
    itemIdB,
    WifiItem(
      title: 'Bravo',
      ssid: 'home-5g',
      password: 'pw',
      createdAt: t0,
      updatedAt: t0,
    ),
  );

  setUpAll(() => registerFallbackValue(login('fallback')));

  setUp(() => repository = MockVaultRepository());

  VaultCubit build() => VaultCubit(repository);

  /// A cubit that has finished its first sync with [entries].
  Future<VaultCubit> loaded(List<VaultEntry> entries) async {
    when(
      () => repository.sync(),
    ).thenAnswer((_) async => delta(upserts: entries));
    final cubit = build();
    await cubit.load();
    return cubit;
  }

  group('load', () {
    blocTest<VaultCubit, VaultState>(
      'full sync, sorted by title',
      build: build,
      setUp: () => when(() => repository.sync()).thenAnswer(
        (_) async => delta(upserts: [bravo, alpha], unreadable: {itemIdC}),
      ),
      act: (cubit) => cubit.load(),
      expect: () => [
        const VaultState(status: VaultStatus.loading),
        VaultState(
          status: VaultStatus.ready,
          entries: [alpha, bravo],
          unreadableCount: 1,
        ),
      ],
    );

    blocTest<VaultCubit, VaultState>(
      'failure keeps a readable message and no stack trace',
      build: build,
      setUp: () => when(() => repository.sync()).thenThrow(
        const ServerException(statusCode: 500, code: 'internal', message: 'x'),
      ),
      act: (cubit) => cubit.load(),
      expect: () => [
        const VaultState(status: VaultStatus.loading),
        const VaultState(
          status: VaultStatus.failure,
          error: 'Server error (500).',
        ),
      ],
    );
  });

  group('refresh (GET /v1/items?since)', () {
    test('sends the last server_time and merges the delta', () async {
      final cubit = await loaded([alpha, bravo]);
      final alpha2 = entry(itemIdA, login('Alpha renamed'), version: 2);
      final charlie = entry(itemIdC, login('Charlie'));
      when(() => repository.sync(since: '2026-11-11T10:00:10Z')).thenAnswer(
        (_) async => delta(
          upserts: [alpha2, charlie],
          deleted: {itemIdB},
          serverTime: '2026-11-11T10:05:00Z',
        ),
      );

      await cubit.refresh();

      expect(cubit.state.entries, [alpha2, charlie]);
      expect(cubit.state.syncing, isFalse);

      // The next refresh continues from the new cursor.
      when(
        () => repository.sync(since: '2026-11-11T10:05:00Z'),
      ).thenAnswer((_) async => delta(serverTime: '2026-11-11T10:06:00Z'));
      await cubit.refresh();
      verify(() => repository.sync(since: '2026-11-11T10:05:00Z')).called(1);
      await cubit.close();
    });

    test('never replaces an item with an older version', () async {
      final current = entry(itemIdA, login('Current'), version: 5);
      final cubit = await loaded([current]);
      when(() => repository.sync(since: any(named: 'since'))).thenAnswer(
        (_) async =>
            delta(upserts: [entry(itemIdA, login('Rolled back'), version: 3)]),
      );

      await cubit.refresh();

      expect(cubit.state.entries.single, current);
      await cubit.close();
    });

    test('a failed refresh keeps the items and reports the error', () async {
      final cubit = await loaded([alpha]);
      when(() => repository.sync(since: any(named: 'since'))).thenThrow(
        const RateLimitedException(
          statusCode: 429,
          code: 'rate_limited',
          message: 'x',
        ),
      );

      await cubit.refresh();

      expect(cubit.state.entries, [alpha]);
      expect(cubit.state.error, 'Too many attempts. Try again later.');
      expect(cubit.state.status, VaultStatus.ready);
      await cubit.close();
    });
  });

  group('search and type filter', () {
    test('filters by type', () async {
      final cubit = await loaded([alpha, bravo]);
      cubit.setTypeFilter(WifiItem.typeName);
      expect(cubit.state.visible, [bravo]);
      cubit.setTypeFilter(null);
      expect(cubit.state.visible, [alpha, bravo]);
      await cubit.close();
    });

    test('searches title, username and URL, never the password', () async {
      final cubit = await loaded([alpha, bravo]);
      cubit.setQuery('ALPH');
      expect(cubit.state.visible, [alpha]);
      cubit.setQuery('aziz@');
      expect(cubit.state.visible, [alpha]);
      cubit.setQuery('example.com');
      expect(cubit.state.visible, [alpha]);
      cubit.setQuery('home-5g');
      expect(cubit.state.visible, [bravo]);
      cubit.setQuery('correct horse');
      expect(cubit.state.visible, isEmpty);
      await cubit.close();
    });
  });

  group('writes', () {
    test('create adds the new entry', () async {
      final cubit = await loaded([alpha]);
      final item = login('Charlie');
      when(
        () => repository.create(item),
      ).thenAnswer((_) async => entry(itemIdC, item));

      expect(await cubit.create(item), SaveResult.saved);
      expect(cubit.state.entries.map((e) => e.id), [itemIdA, itemIdC]);
      await cubit.close();
    });

    test('update replaces the entry with the new version', () async {
      final cubit = await loaded([alpha]);
      final edited = login('Alpha', password: 'new');
      when(
        () => repository.update(id: itemIdA, baseVersion: 1, item: edited),
      ).thenAnswer((_) async => entry(itemIdA, edited, version: 2));

      expect(await cubit.update(alpha, edited), SaveResult.saved);
      expect(cubit.state.entries.single.version, 2);
      expect(cubit.state.entries.single.item, same(edited));
      await cubit.close();
    });

    test('delete removes the entry', () async {
      final cubit = await loaded([alpha, bravo]);
      when(
        () => repository.delete(id: itemIdA, baseVersion: 1),
      ).thenAnswer((_) async {});

      expect(await cubit.delete(alpha), SaveResult.saved);
      expect(cubit.state.entries, [bravo]);
      await cubit.close();
    });

    test('a network error leaves the vault unchanged', () async {
      final cubit = await loaded([alpha]);
      when(() => repository.create(any())).thenThrow(
        const ServerException(statusCode: 503, code: 'x', message: 'x'),
      );

      expect(await cubit.create(login('X')), SaveResult.failed);
      expect(cubit.state.entries, [alpha]);
      expect(cubit.state.error, 'Server error (503).');
      await cubit.close();
    });
  });

  group('409: keep mine / take server', () {
    final mine = login('Alpha', password: 'mine');
    final theirs = entry(
      itemIdA,
      login('Alpha', password: 'theirs'),
      version: 4,
    );

    Future<VaultCubit> conflicted() async {
      final cubit = await loaded([alpha]);
      when(
        () => repository.update(id: itemIdA, baseVersion: 1, item: mine),
      ).thenThrow(VaultConflict(id: itemIdA, serverVersion: 4, server: theirs));
      expect(await cubit.update(alpha, mine), SaveResult.conflict);
      return cubit;
    }

    test('the refused edit is held as a pending conflict', () async {
      final cubit = await conflicted();
      final conflict = cubit.state.conflict!;
      expect(conflict.id, itemIdA);
      expect(conflict.serverVersion, 4);
      expect(conflict.mine, same(mine));
      expect(conflict.server, theirs);
      expect(conflict.isDelete, isFalse);
      // Nothing changed locally yet.
      expect(cubit.state.entries, [alpha]);
      await cubit.close();
    });

    test('keep mine re-sends my item on top of the server version', () async {
      final cubit = await conflicted();
      when(
        () => repository.update(id: itemIdA, baseVersion: 4, item: mine),
      ).thenAnswer((_) async => entry(itemIdA, mine, version: 5));

      expect(await cubit.resolveKeepMine(), SaveResult.saved);

      expect(cubit.state.conflict, isNull);
      expect(cubit.state.entries.single.version, 5);
      expect(cubit.state.entries.single.item, same(mine));
      verify(
        () => repository.update(id: itemIdA, baseVersion: 4, item: mine),
      ).called(1);
      await cubit.close();
    });

    test('keep mine can conflict again if the server moved on', () async {
      final cubit = await conflicted();
      when(
        () => repository.update(id: itemIdA, baseVersion: 4, item: mine),
      ).thenThrow(const VaultConflict(id: itemIdA, serverVersion: 6));

      expect(await cubit.resolveKeepMine(), SaveResult.conflict);
      expect(cubit.state.conflict!.serverVersion, 6);
      expect(cubit.state.conflict!.mine, same(mine));
      await cubit.close();
    });

    test('take server drops my edit and shows the server copy', () async {
      final cubit = await conflicted();

      await cubit.resolveTakeServer();

      expect(cubit.state.conflict, isNull);
      expect(cubit.state.entries, [theirs]);
      verifyNever(
        () => repository.update(id: itemIdA, baseVersion: 4, item: mine),
      );
      await cubit.close();
    });

    test('a refused delete can be forced or abandoned', () async {
      final cubit = await loaded([alpha]);
      when(
        () => repository.delete(id: itemIdA, baseVersion: 1),
      ).thenThrow(VaultConflict(id: itemIdA, serverVersion: 4, server: theirs));
      expect(await cubit.delete(alpha), SaveResult.conflict);
      expect(cubit.state.conflict!.isDelete, isTrue);
      expect(cubit.state.entries, [alpha]);

      when(
        () => repository.delete(id: itemIdA, baseVersion: 4),
      ).thenAnswer((_) async {});
      expect(await cubit.resolveKeepMine(), SaveResult.saved);
      expect(cubit.state.entries, isEmpty);
      await cubit.close();
    });
  });

  test('410: an item deleted elsewhere disappears locally', () async {
    final cubit = await loaded([alpha, bravo]);
    final edited = login('Alpha', password: 'new');
    when(
      () => repository.update(id: itemIdA, baseVersion: 1, item: edited),
    ).thenThrow(const ItemDeletedRemotely(itemIdA));

    expect(await cubit.update(alpha, edited), SaveResult.deletedRemotely);
    expect(cubit.state.entries, [bravo]);
    expect(cubit.state.conflict, isNull);
    await cubit.close();
  });

  test('clear drops every decrypted item (lock)', () async {
    final cubit = await loaded([alpha, bravo]);
    cubit
      ..setQuery('a')
      ..clear();
    expect(cubit.state, const VaultState());
    await cubit.close();
  });

  group('lock while a request is in flight', () {
    test('a full sync that finishes after clear() is dropped', () async {
      final pending = Completer<SyncDelta>();
      when(() => repository.sync()).thenAnswer((_) => pending.future);
      final cubit = build();
      final loading = cubit.load();
      cubit.clear();
      pending.complete(delta(upserts: [alpha, bravo]));
      await loading;
      expect(cubit.state, const VaultState());
      await cubit.close();
    });

    test('a refresh that finishes after clear() is dropped', () async {
      final cubit = await loaded([alpha]);
      final pending = Completer<SyncDelta>();
      when(
        () => repository.sync(since: any(named: 'since')),
      ).thenAnswer((_) => pending.future);
      final refreshing = cubit.refresh();
      cubit.clear();
      pending.complete(delta(upserts: [bravo]));
      await refreshing;
      expect(cubit.state, const VaultState());
      await cubit.close();
    });

    test('a save that finishes after clear() is dropped', () async {
      final cubit = await loaded([alpha]);
      final item = login('Charlie');
      final pending = Completer<VaultEntry>();
      when(() => repository.create(item)).thenAnswer((_) => pending.future);
      final saving = cubit.create(item);
      cubit.clear();
      pending.complete(entry(itemIdC, item));
      expect(await saving, SaveResult.failed);
      expect(cubit.state, const VaultState());
      await cubit.close();
    });
  });
}
