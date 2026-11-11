import 'package:leopard_core/leopard_core.dart';

import '../../../core/network/remote_vault.dart';
import '../domain/sessions_repository.dart';

final class SessionsRepositoryImpl implements SessionsRepository {
  SessionsRepositoryImpl(this._remote);

  static const int auditPageSize = 50;

  final RemoteVault _remote;

  @override
  Future<List<SessionInfo>> list() => _remote.listSessions();

  @override
  Future<void> revoke(String sessionId) async {
    try {
      await _remote.revokeSession(sessionId);
    } on NotFoundException {
      // Already expired or revoked: the goal is reached.
    }
  }

  @override
  Future<int> revokeAllWeb() async {
    final sessions = await _remote.listSessions();
    var revoked = 0;
    for (final session in sessions) {
      if (session.kind == SessionKind.web) {
        await revoke(session.id);
        revoked++;
      }
    }
    return revoked;
  }

  @override
  Future<AuditPage> auditLog({int? before}) =>
      _remote.auditLog(limit: auditPageSize, before: before);
}
