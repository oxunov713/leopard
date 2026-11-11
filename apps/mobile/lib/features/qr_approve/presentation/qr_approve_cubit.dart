import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../../core/error/failures.dart';
import '../domain/qr_login_repository.dart';

enum QrApproveStatus {
  /// The camera is looking for a code.
  scanning,

  /// Fetching the request's details.
  loading,

  /// Showing the request; waiting for Approve or Reject.
  review,

  /// The biometric prompt is showing.
  authenticating,

  /// Sending the approval or rejection.
  submitting,

  approved,
  rejected,

  /// The 60-second window closed before a decision.
  expired,

  /// See [QrApproveState.message].
  failed,
}

final class QrApproveState extends Equatable {
  const QrApproveState({
    this.status = QrApproveStatus.scanning,
    this.request,
    this.message,
  });

  final QrApproveStatus status;
  final QrLoginRequest? request;
  final String? message;

  bool get busy =>
      status == QrApproveStatus.loading ||
      status == QrApproveStatus.authenticating ||
      status == QrApproveStatus.submitting;

  @override
  List<Object?> get props => [status, request, message];
}

/// Scan → review → biometric → approve, for a browser login.
class QrApproveCubit extends Cubit<QrApproveState> {
  QrApproveCubit(this._repository, {DateTime Function() now = DateTime.now})
    : _now = now,
      super(const QrApproveState());

  final QrLoginRepository _repository;
  final DateTime Function() _now;
  Timer? _expiry;

  /// Called by the scanner for every code it sees. Only the first one while
  /// scanning is used.
  Future<void> scanned(String text) async {
    if (state.status != QrApproveStatus.scanning) return;
    emit(const QrApproveState(status: QrApproveStatus.loading));
    try {
      final request = await _repository.load(text);
      if (isClosed) return;
      _expiry?.cancel();
      final remaining = request.expiresAt.difference(_now());
      _expiry = Timer(remaining.isNegative ? Duration.zero : remaining, () {
        if (isClosed) return;
        if (state.status == QrApproveStatus.review ||
            state.status == QrApproveStatus.authenticating) {
          emit(
            QrApproveState(
              status: QrApproveStatus.expired,
              request: state.request,
              message:
                  'The login request expired. Reload the page in the '
                  'browser and scan the new code.',
            ),
          );
        }
      });
      emit(QrApproveState(status: QrApproveStatus.review, request: request));
    } on Object catch (e) {
      _fail(e);
    }
  }

  /// Approve: biometric first, then encrypt, sign and send.
  Future<void> approve() async {
    final request = state.request;
    if (state.status != QrApproveStatus.review || request == null) return;
    emit(
      QrApproveState(status: QrApproveStatus.authenticating, request: request),
    );
    try {
      final present = await _repository.confirmPresence();
      if (isClosed || state.status != QrApproveStatus.authenticating) return;
      if (!present) {
        emit(
          QrApproveState(
            status: QrApproveStatus.review,
            request: request,
            message:
                'Biometric confirmation is required to approve a login. '
                'Nothing was sent.',
          ),
        );
        return;
      }
      emit(
        QrApproveState(status: QrApproveStatus.submitting, request: request),
      );
      await _repository.approve(request);
      _expiry?.cancel();
      if (isClosed) return;
      emit(QrApproveState(status: QrApproveStatus.approved, request: request));
    } on Object catch (e) {
      _fail(e);
    }
  }

  Future<void> reject() async {
    final request = state.request;
    if (state.status != QrApproveStatus.review || request == null) return;
    emit(QrApproveState(status: QrApproveStatus.submitting, request: request));
    try {
      await _repository.reject(request);
      _expiry?.cancel();
      if (isClosed) return;
      emit(QrApproveState(status: QrApproveStatus.rejected, request: request));
    } on Object catch (e) {
      _fail(e);
    }
  }

  /// Back to the camera after a failure or an expired request.
  void scanAgain() {
    _expiry?.cancel();
    emit(const QrApproveState());
  }

  void _fail(Object error) {
    if (isClosed) return;
    _expiry?.cancel();
    final message = switch (error) {
      GoneException() => 'The login request expired before it was approved.',
      ConflictException() =>
        'This login request was already approved, rejected or used.',
      ForbiddenException(code: 'bad_signature') =>
        'The server did not accept this phone\'s signature.',
      _ => describeError(error),
    };
    emit(
      QrApproveState(
        status: QrApproveStatus.failed,
        request: state.request,
        message: message,
      ),
    );
  }

  @override
  Future<void> close() {
    _expiry?.cancel();
    return super.close();
  }
}
