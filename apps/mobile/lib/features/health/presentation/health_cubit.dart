import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:leopard_core/leopard_core.dart';

import '../../vault/domain/vault_entry.dart';

enum HealthStatus { idle, running, done }

final class HealthState extends Equatable {
  const HealthState({this.status = HealthStatus.idle, this.report});

  final HealthStatus status;
  final PasswordAuditReport? report;

  @override
  List<Object?> get props => [
    status,
    report == null ? null : identityHashCode(report),
  ];
}

/// Password health: weak, reused and old passwords.
///
/// The audit runs on the phone over the decrypted items in memory. Nothing
/// derived from a password is stored or sent anywhere.
class HealthCubit extends Cubit<HealthState> {
  HealthCubit({
    PasswordAuditor? auditor,
    DateTime Function() now = DateTime.now,
  }) : _auditor = auditor ?? PasswordAuditor(),
       _now = now,
       super(const HealthState());

  final PasswordAuditor _auditor;
  final DateTime Function() _now;
  int _run = 0;

  Future<void> audit(List<VaultEntry> entries) async {
    final run = ++_run;
    emit(HealthState(status: HealthStatus.running, report: state.report));
    final report = await _auditor.audit([
      for (final entry in entries) AuditInput(id: entry.id, item: entry.item),
    ], now: _now());
    // A newer run supersedes this one.
    if (isClosed || run != _run) return;
    emit(HealthState(status: HealthStatus.done, report: report));
  }
}
