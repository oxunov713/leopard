import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import '../../../core/error/failures.dart';
import '../../../core/security/biometric_authenticator.dart';
import '../domain/unlock_repository.dart';

enum UnlockStatus {
  /// Waiting for the user.
  idle,

  /// The biometric prompt is showing.
  authenticating,

  /// Argon2id is running for the master-password fallback.
  deriving,

  unlocked,
}

final class UnlockState extends Equatable {
  const UnlockState({
    this.status = UnlockStatus.idle,
    this.biometrics,
    this.message,
    this.failedPasswordAttempts = 0,
  });

  final UnlockStatus status;

  /// `null` until checked.
  final BiometricAvailability? biometrics;
  final String? message;
  final int failedPasswordAttempts;

  bool get busy =>
      status == UnlockStatus.authenticating || status == UnlockStatus.deriving;

  bool get canUseBiometrics => biometrics == BiometricAvailability.available;

  UnlockState copyWith({
    UnlockStatus? status,
    BiometricAvailability? biometrics,
    String? Function()? message,
    int? failedPasswordAttempts,
  }) => UnlockState(
    status: status ?? this.status,
    biometrics: biometrics ?? this.biometrics,
    message: message == null ? this.message : message(),
    failedPasswordAttempts:
        failedPasswordAttempts ?? this.failedPasswordAttempts,
  );

  @override
  List<Object?> get props => [
    status,
    biometrics,
    message,
    failedPasswordAttempts,
  ];
}

class UnlockCubit extends Cubit<UnlockState> {
  UnlockCubit(this._repository) : super(const UnlockState());

  final UnlockRepository _repository;

  bool _started = false;

  /// Called once the lock screen is in front of the user: asks for the
  /// biometric straight away if a strong one is enrolled.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final availability = await _repository.biometricAvailability();
    if (isClosed) return;
    emit(state.copyWith(biometrics: availability));
    if (availability == BiometricAvailability.available) {
      await unlockWithBiometrics();
    }
  }

  Future<void> unlockWithBiometrics() async {
    if (state.busy || state.status == UnlockStatus.unlocked) return;
    emit(
      state.copyWith(status: UnlockStatus.authenticating, message: () => null),
    );
    try {
      final outcome = await _repository.unlockWithBiometrics();
      if (isClosed) return;
      emit(switch (outcome) {
        BiometricOutcome.success => state.copyWith(
          status: UnlockStatus.unlocked,
        ),
        BiometricOutcome.cancelled => state.copyWith(status: UnlockStatus.idle),
        BiometricOutcome.lockedOut => state.copyWith(
          status: UnlockStatus.idle,
          message: () =>
              'Too many failed attempts. Use your master password, or try '
              'the biometric again later.',
        ),
        BiometricOutcome.unavailable => state.copyWith(
          status: UnlockStatus.idle,
          message: () =>
              'Biometric unlock is not available right now. Use your '
              'master password.',
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
