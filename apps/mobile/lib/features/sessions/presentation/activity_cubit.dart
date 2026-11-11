import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../domain/sessions_repository.dart';

final class ActivityState extends Equatable {
  const ActivityState({
    this.entries = const [],
    this.loading = false,
    this.loaded = false,
    this.nextBefore,
    this.message,
  });

  /// Audit log entries, newest first.
  final List<AuditEntry> entries;
  final bool loading;

  /// The first page has arrived.
  final bool loaded;

  /// Cursor of the next page; `null` when there is no more.
  final int? nextBefore;
  final String? message;

  bool get hasMore => nextBefore != null;

  @override
  List<Object?> get props => [
    [for (final e in entries) e.id],
    loading,
    loaded,
    nextBefore,
    message,
  ];
}

/// The server's audit log, paged.
class ActivityCubit extends Cubit<ActivityState> {
  ActivityCubit(this._repository) : super(const ActivityState());

  final SessionsRepository _repository;

  Future<void> load() => _fetch(reset: true);

  Future<void> loadMore() async {
    if (state.hasMore) {
      await _fetch(reset: false);
    }
  }

  Future<void> _fetch({required bool reset}) async {
    if (state.loading) return;
    final previous = reset ? const <AuditEntry>[] : state.entries;
    emit(
      ActivityState(
        entries: state.entries,
        loading: true,
        loaded: state.loaded,
        nextBefore: state.nextBefore,
      ),
    );
    try {
      final page = await _repository.auditLog(
        before: reset ? null : state.nextBefore,
      );
      if (isClosed) return;
      emit(
        ActivityState(
          entries: [...previous, ...page.entries],
          loaded: true,
          nextBefore: page.nextBefore,
        ),
      );
    } on Object catch (e) {
      if (isClosed) return;
      emit(
        ActivityState(
          entries: state.entries,
          loaded: state.loaded,
          nextBefore: state.nextBefore,
          message: describeError(e),
        ),
      );
    }
  }
}
