import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

import '../network/leopard_api.dart';
import '../security/secret_clipboard.dart';
import 'vault_session.dart';

enum SessionStatus {
  /// No vault key in memory: the login pages are shown.
  signedOut,

  /// Vault key and session token in memory.
  unlocked,
}

/// Why the browser went back to the login page.
enum SignOutReason {
  /// The user pressed "Log out".
  userRequest,

  /// No keyboard or pointer activity for the idle limit (300 s).
  idle,

  /// The tab was in the background for too long.
  hidden,

  /// The session reached its absolute limit (12 h).
  expired,

  /// The server said the session is gone (401): revoked from the phone,
  /// expired, or unknown.
  ended,

  /// The tab is being closed.
  closing,
}

final class SessionState extends Equatable {
  const SessionState.signedOut({this.reason})
    : status = SessionStatus.signedOut,
      locksInSeconds = null;

  const SessionState.unlocked({this.locksInSeconds})
    : status = SessionStatus.unlocked,
      reason = null;

  final SessionStatus status;

  /// Set after a sign-out, for the notice on the login page.
  final SignOutReason? reason;

  /// Seconds until the idle lock, during its last minute only; otherwise
  /// `null`. Lets the app warn before it locks.
  final int? locksInSeconds;

  bool get isUnlocked => status == SessionStatus.unlocked;

  @override
  List<Object?> get props => [status, reason, locksInSeconds];
}

/// Owns the signed-in state of the browser and every rule that ends it
/// (crypto-spec §11):
///
/// * **idle**: [idleLimit] (300 s) without real user activity;
/// * **absolute**: [absoluteLimit] (12 h) after login, whatever the activity;
/// * **hidden**: the tab stayed in the background for [hiddenLimit];
/// * **401**: the server no longer knows the session;
/// * **logout** and **tab close**.
///
/// Each of them ends in [lock], which erases the vault key, the item key and
/// the session token from memory and clears the clipboard. Decrypted items
/// are dropped by whoever listens to this cubit (see `LeopardApp`).
///
/// **Heartbeats** (`POST /v1/sessions/heartbeat`) are what keeps the session
/// alive on the server, and they are sent only because of real activity:
/// [recordActivity] sends one at most every [heartbeatEvery]; activity inside
/// that window is covered by one trailing heartbeat when the window ends. A
/// page that is merely open sends nothing and is locked by both sides.
///
/// Deadlines are compared against [now] on every [tick] instead of relying
/// on long timers, because browsers throttle and suspend timers in
/// background tabs.
class SessionCubit extends Cubit<SessionState> {
  SessionCubit({
    required VaultSession session,
    required LeopardApi api,
    required SecretClipboard clipboard,
    DateTime Function() now = DateTime.now,
    this.idleLimit = const Duration(seconds: 300),
    this.absoluteLimit = const Duration(hours: 12),
    this.hiddenLimit = const Duration(seconds: 30),
    this.heartbeatEvery = const Duration(seconds: 30),
    this.tickEvery = const Duration(seconds: 1),
    this.warnBefore = const Duration(seconds: 60),
  }) : _session = session,
       _api = api,
       _clipboard = clipboard,
       _now = now,
       super(const SessionState.signedOut()) {
    _sessionSubscription = _session.changes.listen(_onSessionChanged);
    _endedSubscription = _api.sessionEnded.listen(
      (_) => lock(SignOutReason.ended),
    );
  }

  final VaultSession _session;
  final LeopardApi _api;
  final SecretClipboard _clipboard;
  final DateTime Function() _now;

  /// Lock after this long without [recordActivity].
  final Duration idleLimit;

  /// Lock this long after login, regardless of activity.
  final Duration absoluteLimit;

  /// Lock after the tab has been hidden for this long.
  final Duration hiddenLimit;

  /// Smallest gap between two heartbeats.
  final Duration heartbeatEvery;

  /// How often deadlines are checked.
  final Duration tickEvery;

  /// [SessionState.locksInSeconds] is set during this last part of the idle
  /// limit.
  final Duration warnBefore;

  late final StreamSubscription<bool> _sessionSubscription;
  late final StreamSubscription<UnauthorizedException> _endedSubscription;
  Timer? _ticker;
  DateTime? _openedAt;
  DateTime? _lastActivityAt;
  DateTime? _lastHeartbeatAt;
  DateTime? _hiddenAt;
  bool _activitySinceHeartbeat = false;
  bool _heartbeatInFlight = false;
  SignOutReason? _pendingReason;

  void _onSessionChanged(bool unlocked) {
    if (isClosed) return;
    if (unlocked) {
      final now = _now();
      _openedAt = now;
      _lastActivityAt = now;
      // The server starts its idle timer when it creates the session.
      _lastHeartbeatAt = now;
      _activitySinceHeartbeat = false;
      _hiddenAt = null;
      _pendingReason = null;
      _ticker?.cancel();
      _ticker = Timer.periodic(tickEvery, (_) => tick());
      emit(const SessionState.unlocked());
    } else {
      _stopTimers();
      emit(SessionState.signedOut(reason: _pendingReason));
      _pendingReason = null;
    }
  }

  void _stopTimers() {
    _ticker?.cancel();
    _ticker = null;
    _openedAt = null;
    _lastActivityAt = null;
    _lastHeartbeatAt = null;
    _hiddenAt = null;
    _activitySinceHeartbeat = false;
  }

  /// Real user activity: a key press, a pointer press, movement or scroll.
  void recordActivity() {
    if (!_session.isUnlocked) return;
    final now = _now();
    _lastActivityAt = now;
    _activitySinceHeartbeat = true;
    if (state.locksInSeconds != null) {
      emit(const SessionState.unlocked());
    }
    _maybeHeartbeat(now);
  }

  /// Checks every deadline. Runs on a timer while unlocked; also called when
  /// the tab becomes visible again.
  void tick() {
    if (!_session.isUnlocked) return;
    final now = _now();
    final openedAt = _openedAt!;
    final lastActivityAt = _lastActivityAt!;
    final hiddenAt = _hiddenAt;
    if (now.difference(openedAt) >= absoluteLimit) {
      lock(SignOutReason.expired);
      return;
    }
    final idleFor = now.difference(lastActivityAt);
    if (idleFor >= idleLimit) {
      lock(SignOutReason.idle);
      return;
    }
    if (hiddenAt != null && now.difference(hiddenAt) >= hiddenLimit) {
      lock(SignOutReason.hidden);
      return;
    }
    _maybeHeartbeat(now);
    final left = idleLimit - idleFor;
    final warning = left <= warnBefore
        ? (left.inMilliseconds / 1000).ceil()
        : null;
    if (warning != state.locksInSeconds) {
      emit(SessionState.unlocked(locksInSeconds: warning));
    }
  }

  void _maybeHeartbeat(DateTime now) {
    if (!_activitySinceHeartbeat || _heartbeatInFlight) return;
    final last = _lastHeartbeatAt;
    if (last != null && now.difference(last) < heartbeatEvery) return;
    _activitySinceHeartbeat = false;
    _lastHeartbeatAt = now;
    _heartbeatInFlight = true;
    unawaited(_sendHeartbeat());
  }

  Future<void> _sendHeartbeat() async {
    try {
      await _api.heartbeat();
    } on Object {
      // A 401 arrives through LeopardApi.sessionEnded and locks. Anything
      // else (offline, 5xx) is not a reason to lock: if the server stops
      // hearing from this page it ends the session itself.
    } finally {
      _heartbeatInFlight = false;
    }
  }

  /// The tab is no longer visible (another tab, minimised window).
  void onHidden() {
    if (!_session.isUnlocked) return;
    _hiddenAt ??= _now();
  }

  /// The tab is visible again.
  void onVisible() {
    if (_hiddenAt != null) {
      // A timer may not have run while hidden: check the deadlines first.
      tick();
      _hiddenAt = null;
    }
    // A clipboard clear refused in the background can succeed now.
    unawaited(_clipboard.clearNow());
  }

  /// The tab is closing. Best effort: the browser may not let the logout
  /// request leave; the server then ends the session by its idle timer.
  void onPageClosing() => lock(SignOutReason.closing);

  /// The "Log out" button.
  void logout() => lock(SignOutReason.userRequest);

  /// Erases the vault key, the item key and the session token from memory.
  ///
  /// Unless the server itself ended the session, it is also told to revoke
  /// it, so the token is useless even if a copy survived somewhere.
  void lock(SignOutReason reason) {
    unawaited(_clipboard.clearNow());
    if (reason == SignOutReason.ended) {
      _api.clearSession();
    } else {
      unawaited(_revoke());
    }
    if (_session.isUnlocked) {
      _pendingReason = reason;
      _stopTimers();
      _session.close(); // emits through _onSessionChanged
    }
  }

  Future<void> _revoke() async {
    try {
      // Drops the token before it returns, whatever the server answers.
      await _api.logout();
    } on Object {
      _api.clearSession();
    }
  }

  /// Removes the "you were signed out because…" notice.
  void dismissNotice() {
    if (state.status == SessionStatus.signedOut && state.reason != null) {
      emit(const SessionState.signedOut());
    }
  }

  @override
  Future<void> close() async {
    _ticker?.cancel();
    await _sessionSubscription.cancel();
    await _endedSubscription.cancel();
    return super.close();
  }
}

/// The sentence shown on the login page after a sign-out.
String? describeSignOut(SignOutReason? reason) => switch (reason) {
  null || SignOutReason.closing => null,
  SignOutReason.userRequest => 'You are logged out.',
  SignOutReason.idle =>
    'Locked after 5 minutes without activity. The vault key was erased from '
        'this browser.',
  SignOutReason.hidden =>
    'Locked because the tab was in the background. The vault key was erased '
        'from this browser.',
  SignOutReason.expired =>
    'The session reached its 12-hour limit. Sign in again.',
  SignOutReason.ended =>
    'The server ended this session (it expired or was signed out from the '
        'phone).',
};
