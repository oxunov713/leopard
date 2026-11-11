import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import '../error/failures.dart';
import '../network/remote_vault.dart';
import '../security/secret_clipboard.dart';
import '../session/vault_session.dart';
import '../storage/device_store.dart';

enum AppLockStatus {
  /// Reading local state at launch.
  starting,

  /// No vault on this phone yet.
  needsSetup,

  /// Set up, no vault key in memory.
  locked,

  /// Vault key in memory.
  unlocked,

  /// Local secure storage could not be read.
  storageError,
}

final class AppLockState extends Equatable {
  const AppLockState(this.status, {this.message});

  final AppLockStatus status;
  final String? message;

  @override
  List<Object?> get props => [status, message];
}

/// Owns the locked / unlocked state of the app and the auto-lock rule:
/// the vault key is wiped once the app has been in the background for
/// [autoLockAfter].
class AppLockCubit extends Cubit<AppLockState> {
  AppLockCubit({
    required DeviceStore store,
    required VaultSession session,
    required RemoteVault remote,
    required SecretClipboard clipboard,
    DateTime Function() now = DateTime.now,
    this.autoLockAfter = const Duration(seconds: 30),
  }) : _store = store,
       _session = session,
       _remote = remote,
       _clipboard = clipboard,
       _now = now,
       super(const AppLockState(AppLockStatus.starting)) {
    _subscription = _session.changes.listen(_onSessionChanged);
  }

  final DeviceStore _store;
  final VaultSession _session;
  final RemoteVault _remote;
  final SecretClipboard _clipboard;
  final DateTime Function() _now;

  /// How long the app may stay in the background before it locks.
  final Duration autoLockAfter;

  late final StreamSubscription<bool> _subscription;
  Timer? _backgroundTimer;
  DateTime? _backgroundedAt;

  /// Decides between setup and unlock at launch.
  Future<void> start() async {
    try {
      final registration = await _store.readRegistration();
      if (isClosed || _session.isUnlocked) {
        return;
      }
      emit(
        AppLockState(
          registration == null
              ? AppLockStatus.needsSetup
              : AppLockStatus.locked,
        ),
      );
    } on AppFailure catch (e) {
      emit(AppLockState(AppLockStatus.storageError, message: e.message));
    }
  }

  /// Wipes the vault key and everything derived from it.
  void lock() {
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    _backgroundedAt = null;
    _remote.forgetSession();
    unawaited(_clipboard.clearNow());
    if (_session.isUnlocked) {
      _session.close(); // emits through _onSessionChanged
    }
  }

  /// The app is no longer visible.
  void onBackgrounded() {
    if (!_session.isUnlocked || _backgroundedAt != null) {
      return;
    }
    _backgroundedAt = _now();
    // The timer handles the case where the process keeps running; the
    // timestamp check in [onForegrounded] handles the case where Android
    // froze the process and the timer never fired.
    _backgroundTimer = Timer(autoLockAfter, lock);
  }

  /// The app is visible again.
  void onForegrounded() {
    final since = _backgroundedAt;
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    _backgroundedAt = null;
    if (since != null && _now().difference(since) >= autoLockAfter) {
      lock();
    }
  }

  /// Forgets this phone's keys. The vault on the server is untouched.
  Future<void> eraseDevice() async {
    lock();
    await _store.erase();
    emit(const AppLockState(AppLockStatus.needsSetup));
  }

  void _onSessionChanged(bool unlocked) {
    if (isClosed) {
      return;
    }
    emit(
      AppLockState(unlocked ? AppLockStatus.unlocked : AppLockStatus.locked),
    );
  }

  @override
  Future<void> close() async {
    _backgroundTimer?.cancel();
    await _subscription.cancel();
    return super.close();
  }
}
