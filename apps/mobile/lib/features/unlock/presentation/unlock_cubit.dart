import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import '../../../core/error/failures.dart';
import '../../../core/security/device_authenticator.dart';
import '../domain/unlock_repository.dart';

enum UnlockStatus {
  /// Waiting for the user.
  idle,

  /// The system screen-lock prompt is showing.
  authenticating,

  /// Argon2id is running for the master-password fallback.
  deriving,

  unlocked,
}

final class UnlockState extends Equatable {
  const UnlockState({
    this.status = UnlockStatus.idle,
    this.deviceLock,
    this.message,
    this.failedPasswordAttempts = 0,
  });

  final UnlockStatus status;

  /// `null` until checked.
  final DeviceLockStatus? deviceLock;
  final String? message;
  final int failedPasswordAttempts;

  bool get busy =>
      status == UnlockStatus.authenticating || status == UnlockStatus.deriving;

  bool get canUseDeviceLock => deviceLock == DeviceLockStatus.secured;

  /// The phone has no screen lock: the master password is the only gate.
  bool get hasNoScreenLock => deviceLock == DeviceLockStatus.none;

  UnlockState copyWith({
    UnlockStatus? status,
    DeviceLockStatus? deviceLock,
    String? Function()? message,
    int? failedPasswordAttempts,
  }) => UnlockState(
    status: status ?? this.status,
    deviceLock: deviceLock ?? this.deviceLock,
    message: message == null ? this.message : message(),
    failedPasswordAttempts:
        failedPasswordAttempts ?? this.failedPasswordAttempts,
  );

  @override
  List<Object?> get props => [
    status,
    deviceLock,
    message,
    failedPasswordAttempts,
  ];
}

class UnlockCubit extends Cubit<UnlockState> {
  UnlockCubit(this._repository) : super(const UnlockState());

  final UnlockRepository _repository;

  bool _started = false;

  /// Called once the lock screen is in front of the user: shows the system
  /// screen-lock prompt straight away if the phone has a screen lock.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final lock = await _repository.deviceLockStatus();
    if (isClosed) return;
    emit(state.copyWith(deviceLock: lock));
    if (lock == DeviceLockStatus.secured) {
      await unlockWithDeviceCredential();
    }
  }

  Future<void> unlockWithDeviceCredential() async {
    if (state.busy || state.status == UnlockStatus.unlocked) return;
    emit(
      state.copyWith(status: UnlockStatus.authenticating, message: () => null),
    );
    try {
      final outcome = await _repository.unlockWithDeviceCredential();
      if (isClosed) return;
      emit(switch (outcome) {
        DeviceAuthOutcome.success => state.copyWith(
          status: UnlockStatus.unlocked,
        ),
        DeviceAuthOutcome.cancelled => state.copyWith(
          status: UnlockStatus.idle,
        ),
        DeviceAuthOutcome.lockedOut => state.copyWith(
          status: UnlockStatus.idle,
          message: () =>
              'Too many failed attempts. Try again later, or use your '
              'master password.',
        ),
        DeviceAuthOutcome.noScreenLock => state.copyWith(
          status: UnlockStatus.idle,
          deviceLock: DeviceLockStatus.none,
          message: () =>
              'This phone has no screen lock. Use your master password.',
        ),
        DeviceAuthOutcome.unavailable => state.copyWith(
          status: UnlockStatus.idle,
          message: () =>
              'Unlocking with the screen lock is not available right now. '
              'Use your master password.',
        ),
      });
    } on Object catch (e) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: UnlockStatus.idle,
          message: () => describeError(e),
        ),
      );
    }
  }

  Future<void> unlockWithMasterPassword(String masterPassword) async {
    if (state.busy || state.status == UnlockStatus.unlocked) return;
    if (masterPassword.isEmpty) {
      emit(state.copyWith(message: () => 'Enter your master password.'));
      return;
    }
    emit(state.copyWith(status: UnlockStatus.deriving, message: () => null));
    try {
      final ok = await _repository.unlockWithMasterPassword(masterPassword);
      if (isClosed) return;
      emit(
        ok
            ? state.copyWith(status: UnlockStatus.unlocked)
            : state.copyWith(
                status: UnlockStatus.idle,
                failedPasswordAttempts: state.failedPasswordAttempts + 1,
                message: () => 'Wrong master password.',
              ),
      );
    } on Object catch (e) {
      if (isClosed) return;
      emit(
        state.copyWith(
          status: UnlockStatus.idle,
          message: () => describeError(e),
        ),
      );
    }
  }
}
