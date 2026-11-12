import 'dart:typed_data';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../../setup/domain/setup_repository.dart' show parseServerUrl;
import '../domain/restore_repository.dart';

enum RestoreStep {
  /// Server, phone name, recovery key and master password.
  form,

  /// Restored and stored; the user reads what happened, then opens the
  /// vault.
  done,
}

final class RestoreState extends Equatable {
  const RestoreState({
    this.step = RestoreStep.form,
    this.busy = false,
    this.error,
  });

  final RestoreStep step;
  final bool busy;
  final String? error;

  RestoreState copyWith({
    RestoreStep? step,
    bool? busy,
    String? Function()? error,
  }) => RestoreState(
    step: step ?? this.step,
    busy: busy ?? this.busy,
    error: error == null ? this.error : error(),
  );

  @override
  List<Object?> get props => [step, busy, error];
}

/// Shown for a recovery key that cannot be parsed. Nothing was sent.
const String malformedRecoveryKeyMessage =
    'That is not a valid recovery key. It has 26 characters (letters A to Z '
    'and digits 2 to 7), written as XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX. '
    'Nothing was sent to the server.';

/// Turns a restore error into a short sentence for the user.
String describeRestoreError(Object error) => switch (error) {
  UnauthorizedException() =>
    'The server did not accept this recovery key. Check it against your '
        'paper copy. The server allows 5 attempts an hour.',
  RateLimitedException(:final retryAfter) =>
    retryAfter == null
        ? 'Too many recovery attempts. The server allows 5 an hour; wait '
              'and try again later.'
        : 'Too many recovery attempts. Wait ${_waitText(retryAfter)} and '
              'try again.',
  DecryptException() =>
    'The server accepted the recovery key, but the vault key it returned '
        'does not open with it.',
  _ => describeError(error),
};

String _waitText(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds <= 60) {
    return 'a minute';
  }
  final minutes = (seconds + 59) ~/ 60;
  return '$minutes minutes';
}

/// Registers this phone for an existing vault with the paper recovery key.
///
/// The recovery key is checked locally before anything is sent. The server
/// then signs out every other phone and session; the vault key itself stays
/// the same (crypto-spec §8, v1 limitation), which the done step says.
class RestoreCubit extends Cubit<RestoreState> {
  RestoreCubit(this._repository) : super(const RestoreState());

  final RestoreRepository _repository;

  Future<void> submit({
    required String serverUrl,
    required String deviceLabel,
    required String recoveryKey,
    required String masterPassword,
    required String confirmation,
  }) async {
    if (state.busy || state.step != RestoreStep.form) return;
    final uri = parseServerUrl(serverUrl);
    if (uri == null) {
      emit(
        state.copyWith(
          error: () =>
              'Enter the server address, starting with https://. '
              'Unencrypted http is not allowed.',
        ),
      );
      return;
    }
    final label = deviceLabel.trim();
    if (label.isEmpty || label.length > 64) {
      emit(
        state.copyWith(
          error: () => 'Give this phone a name of 1 to 64 characters.',
        ),
      );
      return;
    }
    if (recoveryKey.trim().isEmpty) {
      emit(
        state.copyWith(
          error: () => 'Type the recovery key from your paper copy.',
        ),
      );
      return;
    }
    if (masterPassword.isEmpty) {
      emit(
        state.copyWith(
          error: () => 'Enter the master password that protects this vault.',
        ),
      );
      return;
    }
    // Compared after NFC, the form that is actually used as the key.
    if (LeopardCrypto.normalizePassword(masterPassword) !=
        LeopardCrypto.normalizePassword(confirmation)) {
      emit(state.copyWith(error: () => 'The two passwords do not match.'));
      return;
    }
    final Uint8List key;
    try {
      key = parseRecoveryKey(recoveryKey);
    } on LeopardCryptoException {
      emit(state.copyWith(error: () => malformedRecoveryKeyMessage));
      return;
    }
    emit(state.copyWith(busy: true, error: () => null));
    try {
      await _repository.restore(
        serverUrl: uri,
        deviceLabel: label,
        recoveryKey: key,
        masterPassword: masterPassword,
      );
      if (isClosed) return;
      emit(const RestoreState(step: RestoreStep.done));
    } on Object catch (e) {
      if (isClosed) return;
      emit(state.copyWith(busy: false, error: () => describeRestoreError(e)));
    } finally {
      // The repository wipes it too; this covers an early failure.
      wipe(key);
    }
  }

  /// Opens the restored vault. The router then leaves for the vault.
  Future<void> openVault() async {
    if (state.busy || state.step != RestoreStep.done) return;
    emit(state.copyWith(busy: true, error: () => null));
    try {
      await _repository.openRestoredVault();
    } on Object catch (e) {
      if (isClosed) return;
      emit(state.copyWith(busy: false, error: () => describeError(e)));
    }
  }
}
