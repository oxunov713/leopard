import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../domain/emergency_login_repository.dart';

enum EmergencyLoginStatus { idle, working, signedIn }

final class EmergencyLoginState extends Equatable {
  const EmergencyLoginState({
    this.status = EmergencyLoginStatus.idle,
    this.phase,
    this.elapsedSeconds = 0,
    this.error,
    this.retryInSeconds,
  });

  final EmergencyLoginStatus status;

  /// What is happening while [status] is `working`.
  final EmergencyLoginPhase? phase;

  /// Seconds since the attempt started, shown while the key is derived.
  final int elapsedSeconds;
  final String? error;

  /// After a 429: seconds until the server accepts another attempt.
  final int? retryInSeconds;

  bool get isWorking => status == EmergencyLoginStatus.working;

  /// Whether the form may be submitted.
  bool get canSubmit => !isWorking && (retryInSeconds ?? 0) <= 0;

  @override
  List<Object?> get props => [
    status,
    phase,
    elapsedSeconds,
    error,
    retryInSeconds,
  ];
}

/// Emergency login: master password and TOTP code.
class EmergencyLoginCubit extends Cubit<EmergencyLoginState> {
  EmergencyLoginCubit(this._repository) : super(const EmergencyLoginState());

  final EmergencyLoginRepository _repository;
  Timer? _elapsed;
  Timer? _retry;

  Future<void> submit({
    required String masterPassword,
    required String totpCode,
  }) async {
    if (!state.canSubmit) return;
    _retry?.cancel();
    emit(
      const EmergencyLoginState(
        status: EmergencyLoginStatus.working,
        phase: EmergencyLoginPhase.fetchingParameters,
      ),
    );
    final started = DateTime.now();
    _elapsed?.cancel();
    _elapsed = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isClosed || !state.isWorking) return;
      emit(
        EmergencyLoginState(
          status: EmergencyLoginStatus.working,
          phase: state.phase,
          elapsedSeconds: DateTime.now().difference(started).inSeconds,
        ),
      );
    });
    try {
      await _repository.login(
        masterPassword: masterPassword,
        totpCode: totpCode,
        onPhase: (phase) {
          if (isClosed || !state.isWorking) return;
          emit(
            EmergencyLoginState(
              status: EmergencyLoginStatus.working,
              phase: phase,
              elapsedSeconds: state.elapsedSeconds,
            ),
          );
        },
      );
      if (isClosed) return;
      emit(const EmergencyLoginState(status: EmergencyLoginStatus.signedIn));
    } on RateLimitedException catch (e) {
      if (isClosed) return;
      final wait = e.retryAfter;
      emit(
        EmergencyLoginState(
          error: describeLoginError(e),
          retryInSeconds: wait?.inSeconds,
        ),
      );
      if (wait != null && wait > Duration.zero) {
        _countDownRetry();
      }
    } on Object catch (e) {
      if (isClosed) return;
      emit(EmergencyLoginState(error: describeLoginError(e)));
    } finally {
      _elapsed?.cancel();
      _elapsed = null;
    }
  }

  void _countDownRetry() {
    _retry?.cancel();
    _retry = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = (state.retryInSeconds ?? 0) - 1;
      if (isClosed || state.isWorking) {
        timer.cancel();
        return;
      }
      if (left <= 0) {
        timer.cancel();
        emit(EmergencyLoginState(error: state.error));
      } else {
        emit(EmergencyLoginState(error: state.error, retryInSeconds: left));
      }
    });
  }

  @override
  Future<void> close() {
    _elapsed?.cancel();
    _retry?.cancel();
    return super.close();
  }
}

/// Error text for the emergency login form.
///
/// The server answers a wrong password, a wrong code and a code that was
/// already used with the same `401 invalid_credentials`, on purpose, so the
/// message names all three.
String describeLoginError(Object error) => switch (error) {
  UnauthorizedException(code: 'invalid_credentials') =>
    'The master password or the code is wrong, or this code was already '
        'used. A code works once: wait for the next one (30 s) before '
        'trying again.',
  RateLimitedException(:final retryAfter) =>
    retryAfter == null
        ? 'Too many login attempts. The server allows 5 in 15 minutes; try '
              'again later.'
        : 'Too many login attempts. Try again in '
              '${describeWait(retryAfter)}.',
  _ => describeError(error),
};
