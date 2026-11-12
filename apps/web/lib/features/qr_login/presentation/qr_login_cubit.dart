import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../domain/qr_login_repository.dart';

enum QrLoginStatus {
  /// Creating a request (`POST /v1/qr`).
  starting,

  /// The QR code is on screen and the server is being polled.
  waiting,

  /// The phone approved; the vault key is decrypted and the session opens.
  signedIn,

  /// The phone rejected the request.
  rejected,

  /// The code timed out and was not renewed automatically any more.
  expired,

  /// Something went wrong; see [QrLoginState.error].
  failed,
}

final class QrLoginState extends Equatable {
  const QrLoginState({
    this.status = QrLoginStatus.starting,
    this.qrText,
    this.verifyCode,
    this.secondsLeft = 0,
    this.totalSeconds = 60,
    this.reconnecting = false,
    this.error,
  });

  final QrLoginStatus status;

  /// The text of the QR code while [status] is `waiting`.
  final String? qrText;

  /// The 6-digit code to compare with the phone.
  final String? verifyCode;

  /// Seconds until the code on screen stops working.
  final int secondsLeft;

  /// The lifetime of the code on screen, for the progress bar.
  final int totalSeconds;

  /// The last poll failed (offline, rate limit) and is being retried.
  final bool reconnecting;
  final String? error;

  @override
  List<Object?> get props => [
    status,
    qrText,
    verifyCode,
    secondsLeft,
    totalSeconds,
    reconnecting,
    error,
  ];
}

/// The browser side of QR login as a state machine:
///
/// ```
/// starting ─► waiting ─┬─► signedIn          (approved and decrypted)
///     ▲          │     ├─► rejected          (rejected on the phone)
///     │          │     ├─► failed            (mismatch, consumed, API error)
///     └──────────┘     └─► expired           (after the automatic renewals)
///      renew at 60 s
/// ```
///
/// While waiting, `GET /v1/qr/{sid}` is polled every [pollEvery]; one poll
/// runs at a time. A failed poll (network, 5xx, 429) doubles the delay up to
/// [maxBackoff], or waits for `Retry-After`, and the first good answer
/// resets it. A code that runs out is replaced automatically
/// [maxAutoRenewals] times, then the page asks before making more requests,
/// so a forgotten tab stops talking to the server after a few minutes.
class QrLoginCubit extends Cubit<QrLoginState> {
  QrLoginCubit(
    this._repository, {
    DateTime Function() now = DateTime.now,
    this.pollEvery = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 10),
    this.codeLifetime = const Duration(seconds: 60),
    this.maxAutoRenewals = 4,
  }) : _now = now,
       super(const QrLoginState());

  final QrLoginRepository _repository;
  final DateTime Function() _now;

  /// Delay between polls while everything works.
  final Duration pollEvery;

  /// Largest delay between polls while they fail.
  final Duration maxBackoff;

  /// How long a request lives on the server (crypto-spec §10.1: 60 s).
  final Duration codeLifetime;

  /// How many times an expired code is replaced without asking.
  final int maxAutoRenewals;

  QrLoginAttempt? _attempt;
  DateTime? _deadline;
  Timer? _pollTimer;
  Timer? _countdown;
  Duration _backoff = Duration.zero;
  int _renewals = 0;

  /// Bumped whenever the current attempt is replaced or dropped, so that the
  /// answer to an old request is ignored.
  int _generation = 0;

  /// Shows a first code. Also the "show a new code" button.
  Future<void> start() {
    _renewals = 0;
    return _begin();
  }

  Future<void> _begin() async {
    _dropAttempt();
    final generation = _generation;
    emit(const QrLoginState());
    final QrLoginAttempt attempt;
    try {
      attempt = await _repository.begin();
    } on Object catch (e) {
      if (isClosed || generation != _generation) return;
      emit(QrLoginState(status: QrLoginStatus.failed, error: describeError(e)));
      return;
    }
    if (isClosed || generation != _generation) {
      _repository.abandon(attempt);
      return;
    }
    _attempt = attempt;
    _backoff = Duration.zero;
    // The lifetime is taken from the server's expiry when this machine's
    // clock agrees with it, and from the protocol constant when it does not.
    final now = _now();
    var lifetime = attempt.expiresAt.difference(now);
    if (lifetime <= Duration.zero || lifetime > codeLifetime) {
      lifetime = codeLifetime;
    }
    _deadline = now.add(lifetime);
    emit(
      QrLoginState(
        status: QrLoginStatus.waiting,
        qrText: attempt.qrText,
        verifyCode: attempt.verifyCode,
        secondsLeft: _ceilSeconds(lifetime),
        totalSeconds: _ceilSeconds(lifetime),
      ),
    );
    _countdown = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _onCountdown(generation),
    );
    _schedulePoll(generation, pollEvery);
  }

  static int _ceilSeconds(Duration d) => (d.inMilliseconds / 1000).ceil();

  void _onCountdown(int generation) {
    if (isClosed || generation != _generation) return;
    final deadline = _deadline;
    if (deadline == null || state.status != QrLoginStatus.waiting) return;
    final left = deadline.difference(_now());
    if (left <= Duration.zero) {
      // The server reports `expired` on the next poll at the latest; this
      // covers the case where polls are not getting through.
      _onExpired();
      return;
    }
    final seconds = _ceilSeconds(left);
    if (seconds != state.secondsLeft) {
      emit(_waiting(secondsLeft: seconds));
    }
  }

  QrLoginState _waiting({int? secondsLeft, bool? reconnecting}) => QrLoginState(
    status: QrLoginStatus.waiting,
    qrText: state.qrText,
    verifyCode: state.verifyCode,
    secondsLeft: secondsLeft ?? state.secondsLeft,
    totalSeconds: state.totalSeconds,
    reconnecting: reconnecting ?? state.reconnecting,
  );

  void _schedulePoll(int generation, Duration delay) {
    _pollTimer?.cancel();
    _pollTimer = Timer(delay, () => unawaited(_poll(generation)));
  }

  Future<void> _poll(int generation) async {
    final attempt = _attempt;
    if (isClosed || generation != _generation || attempt == null) return;
    final QrPollOutcome outcome;
    try {
      outcome = await _repository.poll(attempt);
    } on ServerMismatchFailure catch (e) {
      if (isClosed || generation != _generation) return;
      _finish(QrLoginState(status: QrLoginStatus.failed, error: e.message));
      return;
    } on RateLimitedException catch (e) {
      if (isClosed || generation != _generation) return;
      _retryLater(generation, atLeast: e.retryAfter);
      return;
    } on MalformedResponseException catch (e) {
      if (isClosed || generation != _generation) return;
      _finish(
        QrLoginState(status: QrLoginStatus.failed, error: describeError(e)),
      );
      return;
    } on Object {
      // Offline, a timeout, a 5xx: keep the code on screen and try again.
      if (isClosed || generation != _generation) return;
      _retryLater(generation);
      return;
    }
    if (isClosed || generation != _generation) return;
    _backoff = Duration.zero;
    switch (outcome) {
      case QrPollOutcome.pending:
        if (state.reconnecting) {
          emit(_waiting(reconnecting: false));
        }
        _schedulePoll(generation, pollEvery);
      case QrPollOutcome.signedIn:
        _finish(const QrLoginState(status: QrLoginStatus.signedIn));
      case QrPollOutcome.rejected:
        _finish(const QrLoginState(status: QrLoginStatus.rejected));
      case QrPollOutcome.expired:
        _onExpired();
      case QrPollOutcome.consumed:
        _finish(
          const QrLoginState(
            status: QrLoginStatus.failed,
            error:
                'This code was already used. If that was not you, check the '
                'active sessions on your phone.',
          ),
        );
    }
  }

  void _retryLater(int generation, {Duration? atLeast}) {
    final doubled = _backoff == Duration.zero ? pollEvery * 2 : _backoff * 2;
    _backoff = doubled > maxBackoff ? maxBackoff : doubled;
    var delay = _backoff;
    if (atLeast != null && atLeast > delay) {
      delay = atLeast;
    }
    if (!state.reconnecting) {
      emit(_waiting(reconnecting: true));
    }
    _schedulePoll(generation, delay);
  }

  void _onExpired() {
    if (_renewals < maxAutoRenewals) {
      _renewals++;
      unawaited(_begin());
    } else {
      _finish(const QrLoginState(status: QrLoginStatus.expired));
    }
  }

  /// Ends the current attempt with a terminal [next] state.
  void _finish(QrLoginState next) {
    _dropAttempt();
    emit(next);
  }

  void _dropAttempt() {
    _generation++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _countdown?.cancel();
    _countdown = null;
    _deadline = null;
    final attempt = _attempt;
    _attempt = null;
    if (attempt != null) {
      _repository.abandon(attempt);
    }
  }

  /// Stops polling and wipes the ephemeral key (the page was left).
  @override
  Future<void> close() {
    _dropAttempt();
    return super.close();
  }
}
