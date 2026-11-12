import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../domain/vault_entry.dart';
import '../domain/vault_repository.dart';

enum VaultStatus { initial, loading, ready, failure }

/// What happened to a create / update / delete request.
enum SaveResult {
  saved,

  /// The server has a different version; see [VaultState.conflict].
  conflict,

  /// The item was deleted on another device.
  deletedRemotely,

  /// See [VaultState.error].
  failed,
}

/// A write that the server refused with `409 version_conflict`, waiting for
/// the user to choose between "keep mine" and "take server".
final class PendingConflict extends Equatable {
  const PendingConflict({
    required this.id,
    required this.serverVersion,
    required this.mine,
    this.server,
  });

  final String id;
  final int serverVersion;

  /// What the user tried to save; `null` when they tried to delete.
  final VaultItem? mine;

  /// The server's copy, if it could be read.
  final VaultEntry? server;

  bool get isDelete => mine == null;

  @override
  List<Object?> get props => [
    id,
    serverVersion,
    mine == null ? null : identityHashCode(mine),
    server,
  ];
}

final class VaultState extends Equatable {
  const VaultState({
    this.status = VaultStatus.initial,
    this.entries = const [],
    this.query = '',
    this.typeFilter,
    this.syncing = false,
    this.unreadableCount = 0,
    this.error,
    this.conflict,
  });

  final VaultStatus status;

  /// Every decrypted item, sorted by title.
  final List<VaultEntry> entries;
  final String query;

  /// Item type name to show, or `null` for all types.
  final String? typeFilter;
  final bool syncing;

  /// Items on the server that this browser could not decrypt or parse.
  final int unreadableCount;
  final String? error;
  final PendingConflict? conflict;

  /// [entries] after the type filter and the search.
  List<VaultEntry> get visible => [
    for (final entry in entries)
      if ((typeFilter == null || entry.item.type == typeFilter) &&
          entryMatches(entry, query))
        entry,
  ];

  VaultEntry? byId(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  VaultState copyWith({
    VaultStatus? status,
    List<VaultEntry>? entries,
    String? query,
    String? Function()? typeFilter,
    bool? syncing,
    int? unreadableCount,
    String? Function()? error,
    PendingConflict? Function()? conflict,
  }) => VaultState(
    status: status ?? this.status,
    entries: entries ?? this.entries,
    query: query ?? this.query,
    typeFilter: typeFilter == null ? this.typeFilter : typeFilter(),
    syncing: syncing ?? this.syncing,
    unreadableCount: unreadableCount ?? this.unreadableCount,
    error: error == null ? this.error : error(),
    conflict: conflict == null ? this.conflict : conflict(),
  );

  @override
  List<Object?> get props => [
    status,
    entries,
    query,
    typeFilter,
    syncing,
    unreadableCount,
    error,
    conflict,
  ];
}

/// The decrypted vault in memory, and every change to it.
class VaultCubit extends Cubit<VaultState> {
  VaultCubit(this._repository) : super(const VaultState());

  final VaultRepository _repository;

  /// `server_time` of the last sync: the cursor for the next one.
  String? _cursor;
  final Set<String> _unreadable = {};

  /// Bumped by [clear]. A request that started under an older generation
  /// must not put its (decrypted) result back into memory after the session
  /// ended (crypto-spec §11).
  int _generation = 0;

  bool _isStale(int generation) => isClosed || generation != _generation;

  /// Full sync, replacing whatever is in memory. Called after login.
  Future<void> load() async {
    if (state.status == VaultStatus.loading) return;
    final generation = _generation;
    emit(state.copyWith(status: VaultStatus.loading, error: () => null));
    try {
      final delta = await _repository.sync();
      if (_isStale(generation)) return;
      _cursor = delta.serverTime;
      _unreadable
        ..clear()
        ..addAll(delta.unreadableIds);
      emit(
        state.copyWith(
          status: VaultStatus.ready,
          entries: [...delta.upserts]..sort(compareEntries),
          unreadableCount: _unreadable.length,
        ),
      );
    } on Object catch (e) {
      if (_isStale(generation)) return;
      emit(
        state.copyWith(
          status: VaultStatus.failure,
          error: () => describeError(e),
        ),
      );
    }
  }

  /// Incremental sync (`GET /v1/items?since=`), merged into memory.
  Future<void> refresh() async {
    if (state.status != VaultStatus.ready) {
      return load();
    }
    if (state.syncing) return;
    final generation = _generation;
    emit(state.copyWith(syncing: true, error: () => null));
    try {
      final delta = await _repository.sync(since: _cursor);
      if (_isStale(generation)) return;
      _cursor = delta.serverTime;
      final byId = {for (final entry in state.entries) entry.id: entry};
      for (final entry in delta.upserts) {
        final known = byId[entry.id];
        // Never go backwards: an older version than the one already seen is
        // a stale or rolled-back copy (crypto-spec §1).
        if (known == null || entry.version >= known.version) {
          byId[entry.id] = entry;
        }
        _unreadable.remove(entry.id);
      }
      for (final id in delta.deletedIds) {
        byId.remove(id);
        _unreadable.remove(id);
      }
      _unreadable.addAll(delta.unreadableIds);
      delta.unreadableIds.forEach(byId.remove);
      emit(
        state.copyWith(
          syncing: false,
          entries: byId.values.toList()..sort(compareEntries),
          unreadableCount: _unreadable.length,
        ),
      );
    } on Object catch (e) {
      if (_isStale(generation)) return;
      emit(state.copyWith(syncing: false, error: () => describeError(e)));
    }
  }

  void setQuery(String query) => emit(state.copyWith(query: query));

  void setTypeFilter(String? type) =>
      emit(state.copyWith(typeFilter: () => type));

  Future<SaveResult> create(VaultItem item) => _write((generation) async {
    final entry = await _repository.create(item);
    _put(entry, generation);
  });

  Future<SaveResult> update(VaultEntry base, VaultItem item) => _write(
    (generation) async {
      final entry = await _repository.update(
        id: base.id,
        baseVersion: base.version,
        item: item,
      );
      _put(entry, generation);
    },
    id: base.id,
    mine: item,
  );

  Future<SaveResult> delete(VaultEntry entry) => _write((generation) async {
    await _repository.delete(id: entry.id, baseVersion: entry.version);
    _remove(entry.id, generation);
  }, id: entry.id);

  /// Conflict answer "keep mine": write my version on top of the server's
  /// (or delete the server's, if the refused request was a delete).
  Future<SaveResult> resolveKeepMine() {
    final conflict = state.conflict;
    if (conflict == null) return Future.value(SaveResult.failed);
    final mine = conflict.mine;
    emit(state.copyWith(conflict: () => null));
    return _write(
      (generation) async {
        if (mine == null) {
          await _repository.delete(
            id: conflict.id,
            baseVersion: conflict.serverVersion,
          );
          _remove(conflict.id, generation);
        } else {
          final entry = await _repository.update(
            id: conflict.id,
            baseVersion: conflict.serverVersion,
            item: mine,
          );
          _put(entry, generation);
        }
      },
      id: conflict.id,
      mine: mine,
    );
  }

  /// Conflict answer "take server": drop my change and show the server's
  /// copy.
  Future<void> resolveTakeServer() async {
    final conflict = state.conflict;
    if (conflict == null) return;
    final server = conflict.server;
    emit(state.copyWith(conflict: () => null));
    if (server != null) {
      _put(server, _generation);
    } else {
      // The server's copy could not be read here; fetch whatever changed.
      await refresh();
    }
  }

  /// Drops every decrypted item. Called when the session ends.
  void clear() {
    _generation++;
    _cursor = null;
    _unreadable.clear();
    emit(const VaultState());
  }

  Future<SaveResult> _write(
    Future<void> Function(int generation) action, {
    String? id,
    VaultItem? mine,
  }) async {
    final generation = _generation;
    emit(state.copyWith(error: () => null));
    try {
      await action(generation);
      if (_isStale(generation)) return SaveResult.failed;
      return SaveResult.saved;
    } on VaultConflict catch (conflict) {
      if (_isStale(generation)) return SaveResult.failed;
      emit(
        state.copyWith(
          conflict: () => PendingConflict(
            id: conflict.id,
            serverVersion: conflict.serverVersion,
            mine: mine,
            server: conflict.server,
          ),
        ),
      );
      return SaveResult.conflict;
    } on ItemDeletedRemotely catch (gone) {
      if (_isStale(generation)) return SaveResult.failed;
      _remove(gone.id, generation);
      return SaveResult.deletedRemotely;
    } on Object catch (e) {
      if (_isStale(generation)) return SaveResult.failed;
      emit(state.copyWith(error: () => describeError(e)));
      return SaveResult.failed;
    }
  }

  void _put(VaultEntry entry, int generation) {
    if (_isStale(generation)) return;
    emit(
      state.copyWith(
        entries: [
          for (final existing in state.entries)
            if (existing.id != entry.id) existing,
          entry,
        ]..sort(compareEntries),
      ),
    );
  }

  void _remove(String id, int generation) {
    if (_isStale(generation)) return;
    emit(
      state.copyWith(
        entries: [
          for (final existing in state.entries)
            if (existing.id != id) existing,
        ],
      ),
    );
  }
}
