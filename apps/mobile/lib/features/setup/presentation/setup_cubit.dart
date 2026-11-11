import 'dart:math';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../domain/setup_repository.dart';

enum SetupStep { server, password, recoveryKey, recoveryCheck, totp, done }

final class SetupState extends Equatable {
  const SetupState({
    this.step = SetupStep.server,
    this.busy = false,
    this.error,
    this.passwordBits = 0,
    this.passwordProblem,
    this.recoveryKey = '',
    this.recoveryAcknowledged = false,
    this.challengeGroups = const [],
    this.totpUri = '',
    this.totpSecret = '',
  });

  final SetupStep step;
  final bool busy;
  final String? error;

  /// Strength estimate of the password being typed, in bits.
  final double passwordBits;

  /// Why the typed password is not acceptable; `null` when it is.
  final String? passwordProblem;

  /// The recovery key in display form (`XXXX-XXXX-…-XX`).
  final String recoveryKey;
  final bool recoveryAcknowledged;

  /// Zero-based indexes of the two groups the user must type back.
  final List<int> challengeGroups;

  /// `otpauth://` URI and Base32 secret for the authenticator app.
  final String totpUri;
  final String totpSecret;

  List<String> get recoveryGroups =>
      recoveryKey.isEmpty ? const [] : recoveryKey.split('-');

  SetupState copyWith({
    SetupStep? step,
    bool? busy,
    String? Function()? error,
    double? passwordBits,
    String? Function()? passwordProblem,
    String? recoveryKey,
    bool? recoveryAcknowledged,
    List<int>? challengeGroups,
    String? totpUri,
    String? totpSecret,
  }) => SetupState(
    step: step ?? this.step,
    busy: busy ?? this.busy,
    error: error == null ? this.error : error(),
    passwordBits: passwordBits ?? this.passwordBits,
    passwordProblem: passwordProblem == null
        ? this.passwordProblem
        : passwordProblem(),
    recoveryKey: recoveryKey ?? this.recoveryKey,
    recoveryAcknowledged: recoveryAcknowledged ?? this.recoveryAcknowledged,
    challengeGroups: challengeGroups ?? this.challengeGroups,
    totpUri: totpUri ?? this.totpUri,
    totpSecret: totpSecret ?? this.totpSecret,
  );

  @override
  List<Object?> get props => [
    step,
    busy,
    error,
    passwordBits,
    passwordProblem,
    recoveryKey,
    recoveryAcknowledged,
    challengeGroups,
    totpUri,
    totpSecret,
  ];
}

/// Picks which two of [groupCount] recovery-key groups to ask for.
typedef ChallengePicker = List<int> Function(int groupCount);

List<int> pickTwoGroups(int groupCount) {
  final random = Random.secure();
  final first = random.nextInt(groupCount);
  var second = random.nextInt(groupCount - 1);
  if (second >= first) {
    second++;
  }
  return [first, second]..sort();
}

/// First-run wizard.
///
/// Everything is generated and confirmed on the phone first (password,
/// recovery key written down and typed back, authenticator enrolled and a
/// code verified). Only then is the server asked to create the vault, so a
/// vault never exists whose recovery key nobody wrote down.
class SetupCubit extends Cubit<SetupState> {
  SetupCubit(this._repository, {ChallengePicker pickChallenge = pickTwoGroups})
    : _pickChallenge = pickChallenge,
      super(const SetupState());

  final SetupRepository _repository;
  final ChallengePicker _pickChallenge;

  Uri? _serverUrl;
  String? _setupToken;
  String _deviceLabel = '';
  VaultSetupMaterial? _material;

  Future<void> submitServer({
    required String serverUrl,
    required String deviceLabel,
    String setupToken = '',
  }) async {
    if (state.busy) return;
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
    emit(state.copyWith(busy: true, error: () => null));
    try {
      await _repository.checkServer(uri);
      _serverUrl = uri;
      _deviceLabel = label;
      _setupToken = setupToken.trim().isEmpty ? null : setupToken.trim();
      emit(state.copyWith(busy: false, step: SetupStep.password));
    } on Object catch (e) {
      emit(state.copyWith(busy: false, error: () => describeError(e)));
    }
  }

  void passwordChanged(String password) {
    emit(
      state.copyWith(
        passwordBits: password.isEmpty
            ? 0
            : estimatePasswordStrength(password).bits,
        passwordProblem: () => password.isEmpty
            ? null
            : MasterPasswordPolicy.problemWith(password),
        error: () => null,
      ),
    );
  }

  Future<void> submitPassword({
    required String password,
    required String confirmation,
  }) async {
    if (state.busy) return;
    final problem = MasterPasswordPolicy.problemWith(password);
    if (problem != null) {
      emit(state.copyWith(error: () => problem));
      return;
    }
    // Compared after NFC, the form that is actually used as the key.
    if (LeopardCrypto.normalizePassword(password) !=
        LeopardCrypto.normalizePassword(confirmation)) {
      emit(state.copyWith(error: () => 'The two passwords do not match.'));
      return;
    }
    emit(state.copyWith(busy: true, error: () => null));
    try {
      _material?.destroy();
      final material = await _repository.prepare(password);
      if (isClosed) {
        material.destroy();
        return;
      }
      _material = material;
      final recoveryKey = formatRecoveryKey(material.recoveryKey);
      emit(
        state.copyWith(
          busy: false,
          step: SetupStep.recoveryKey,
          recoveryKey: recoveryKey,
          recoveryAcknowledged: false,
          challengeGroups: _pickChallenge(recoveryKey.split('-').length),
          totpUri: LeopardCrypto.totpProvisioningUri(
            secret: material.totpSecret,
            accountName: _deviceLabel,
          ),
          totpSecret: base32EncodeNoPad(material.totpSecret),
        ),
      );
    } on Object catch (e) {
      emit(state.copyWith(busy: false, error: () => describeError(e)));
    }
  }

  void acknowledgeRecoveryKey(bool value) {
    emit(state.copyWith(recoveryAcknowledged: value, error: () => null));
  }

  void continueFromRecoveryKey() {
    if (!state.recoveryAcknowledged) {
      emit(
        state.copyWith(
          error: () => 'Confirm that you wrote the recovery key down.',
        ),
      );
      return;
    }
    emit(state.copyWith(step: SetupStep.recoveryCheck, error: () => null));
  }

  /// [answers] are the two groups the user typed, in the order of
  /// [SetupState.challengeGroups].
  void submitRecoveryCheck(List<String> answers) {
    final groups = state.recoveryGroups;
    final wanted = state.challengeGroups;
    var ok = answers.length == wanted.length;
    for (var i = 0; ok && i < wanted.length; i++) {
      ok = answers[i].trim().toUpperCase() == groups[wanted[i]];
    }
    if (!ok) {
      emit(
        state.copyWith(
          error: () =>
              'That does not match the recovery key. Check what you '
              'wrote down.',
        ),
      );
      return;
    }
    emit(state.copyWith(step: SetupStep.totp, error: () => null));
  }

  /// Verifies the authenticator code, then creates the vault.
  Future<void> submitTotpCode(String code) async {
    final material = _material;
    final serverUrl = _serverUrl;
    if (state.busy || material == null || serverUrl == null) return;
    emit(state.copyWith(busy: true, error: () => null));
    try {
      final valid = await _repository.verifyTotpCode(
        secret: material.totpSecret,
        code: code,
      );
      if (!valid) {
        emit(
          state.copyWith(
            busy: false,
            error: () =>
                'That code is not valid. Check the authenticator app and '
                'the clock of this phone.',
          ),
        );
        return;
      }
      await _repository.commit(
        material: material,
        serverUrl: serverUrl,
        deviceLabel: _deviceLabel,
        setupToken: _setupToken,
      );
      _material = null;
      if (isClosed) return;
      emit(
        // The secrets shown during setup leave the state with the last step.
        const SetupState(step: SetupStep.done),
      );
    } on Object catch (e) {
      if (isClosed) return;
      emit(state.copyWith(busy: false, error: () => describeError(e)));
    }
  }

  /// One step back. Going back from the recovery key discards the generated
  /// vault: a new password means new keys.
  void back() {
    if (state.busy) return;
    switch (state.step) {
      case SetupStep.server || SetupStep.done:
        return;
      case SetupStep.password:
        emit(const SetupState());
      case SetupStep.recoveryKey:
        _material?.destroy();
        _material = null;
        emit(const SetupState(step: SetupStep.password));
      case SetupStep.recoveryCheck:
        emit(state.copyWith(step: SetupStep.recoveryKey, error: () => null));
      case SetupStep.totp:
        emit(state.copyWith(step: SetupStep.recoveryCheck, error: () => null));
    }
  }

  @override
  Future<void> close() {
    _material?.destroy();
    _material = null;
    return super.close();
  }
}
