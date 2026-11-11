import 'package:leopard_core/leopard_core.dart';

abstract interface class SessionsRepository {
  /// Live sessions, newest first.
  Future<List<SessionInfo>> list();

  Future<void> revoke(String sessionId);

  /// Revokes every web session. Returns how many were revoked.
  Future<int> revokeAllWeb();

  /// One page of the server's audit log, newest first.
  Future<AuditPage> auditLog({int? before});
}
