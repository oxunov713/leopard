import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../domain/sessions_repository.dart';

enum SessionsStatus { loading, ready, failure }

final class SessionsState extends Equatable {
  const SessionsState({
    this.status = SessionsStatus.loading,
    this.sessions = const [],
    this.busy = false,
    this.message,
  });

  final SessionsStatus status;
  final List<SessionInfo> sessions;

  /// A revoke is in flight.
  final bool busy;
  final String? message;

  int get webSessionCount =>
      sessions.where((s) => s.kind == SessionKind.web).length;

  @override
  List<Object?> get props => [
    status,
    [for (final s in sessions) s.id],
    busy,
    message,
  ];
}

class SessionsCubit extends Cubit<SessionsState> {
  SessionsCubit(this._repository) : super(const SessionsState());

  final SessionsRepository _repository;

  Future<void> load() async {
    try {
      final sessions = await _repository.list();
      if (isClosed) return;
      emit(SessionsState(status: SessionsStatus.ready, sessions: sessions));
    } on Object catch (e) {
      if (isClosed) return;
      emit(
        SessionsState(
          status: SessionsStatus.failure,
          sessions: state.sessions,
          message: describeError(e),
        ),
      );
    }
  }

  Future<void> revoke(String sessionId) => _mutate(() async {
    await _repository.revoke(sessionId);
    return 'Session signed out.';
  });

  Future<void> revokeAllWeb() => _mutate(() async {
    final count = await _repository.revokeAllWeb();
    return count == 0
        ? 'There were no web sessions.'
        : 'Signed out $count web session${count == 1 ? '' : 's'}.';
  });

  Future<void> _mutate(Future<String> Function() action) async {
    if (state.busy) return;
    emit(
      SessionsState(status: state.status, sessions: state.sessions, busy: true),
    );
    try {
      final message = await action();
      final sessions = await _repository.list();
      if (isClosed) return;
      emit(
        SessionsState(
          status: SessionsStatus.ready,
          sessions: sessions,
          message: message,
        ),
      );
    } on Object catch (e) {
      if (isClosed) return;
      emit(
        SessionsState(
          status: state.status,
          sessions: state.sessions,
          message: describeError(e),
        ),
      );
    }
  }
}
