import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/features/sessions/data/sessions_repository_impl.dart';
import 'package:leopard_mobile/features/sessions/presentation/activity_cubit.dart';
import 'package:leopard_mobile/features/sessions/presentation/sessions_cubit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

SessionInfo sessionInfo(String id, SessionKind kind, {bool current = false}) =>
    SessionInfo(
      id: id,
      kind: kind,
      deviceId: deviceIdA,
      clientInfo: const {
        'reported': {'browser': 'Firefox', 'platform': 'Linux'},
      },
      ip: '203.0.113.50',
      createdAt: t0,
      lastSeen: t0,
      idleTimeoutSeconds: kind == SessionKind.web ? 300 : 86400,
      expiresAt: t0.add(const Duration(minutes: 5)),
      current: current,
    );

AuditEntry auditEntry(int id, String event) => AuditEntry(
  id: id,
  timestamp: t0,
  event: event,
  sessionId: null,
  deviceId: null,
  ip: '198.51.100.7',
  meta: const {},
);

void main() {
  final phone = sessionInfo(itemIdA, SessionKind.mobile, current: true);
  final web1 = sessionInfo(itemIdB, SessionKind.web);
  final web2 = sessionInfo(itemIdC, SessionKind.web);

  group('SessionsRepositoryImpl', () {
    late MockRemoteVault remote;
    late SessionsRepositoryImpl repository;

    setUp(() {
      remote = MockRemoteVault();
      repository = SessionsRepositoryImpl(remote);
      when(
        () => remote.listSessions(),
      ).thenAnswer((_) async => [web1, phone, web2]);
      when(() => remote.revokeSession(any())).thenAnswer((_) async {});
    });

    test('"sign out all web sessions" leaves the phone signed in', () async {
      expect(await repository.revokeAllWeb(), 2);
      verify(() => remote.revokeSession(itemIdB)).called(1);
      verify(() => remote.revokeSession(itemIdC)).called(1);
      verifyNever(() => remote.revokeSession(itemIdA));
    });

    test('a session that already ended counts as signed out', () async {
      when(() => remote.revokeSession(itemIdB)).thenThrow(
        const NotFoundException(
          statusCode: 404,
          code: 'session_not_found',
          message: 'x',
        ),
      );
      await repository.revoke(itemIdB);
      expect(await repository.revokeAllWeb(), 2);
    });

    test('the audit log is fetched in pages', () async {
      when(
        () => remote.auditLog(
          limit: any(named: 'limit'),
          before: any(named: 'before'),
        ),
      ).thenAnswer((_) async => const AuditPage(entries: [], nextBefore: null));
      await repository.auditLog(before: 42);
      verify(
        () => remote.auditLog(
          limit: SessionsRepositoryImpl.auditPageSize,
          before: 42,
        ),
      ).called(1);
    });
  });

  group('SessionsCubit', () {
    late MockSessionsRepository repository;

    setUp(() {
      repository = MockSessionsRepository();
      when(
        () => repository.list(),
      ).thenAnswer((_) async => [web1, phone, web2]);
      when(() => repository.revoke(any())).thenAnswer((_) async {});
      when(() => repository.revokeAllWeb()).thenAnswer((_) async => 2);
    });

    test('load lists web and mobile sessions', () async {
      final cubit = SessionsCubit(repository);
      expect(cubit.state.status, SessionsStatus.loading);
      await cubit.load();
      expect(cubit.state.status, SessionsStatus.ready);
      expect(cubit.state.sessions, [web1, phone, web2]);
      expect(cubit.state.webSessionCount, 2);
      await cubit.close();
    });

    test('revoke signs one session out and reloads', () async {
      final cubit = SessionsCubit(repository);
      await cubit.load();
      when(() => repository.list()).thenAnswer((_) async => [phone, web2]);

      await cubit.revoke(itemIdB);

      verify(() => repository.revoke(itemIdB)).called(1);
      expect(cubit.state.sessions, [phone, web2]);
      expect(cubit.state.busy, isFalse);
      expect(cubit.state.message, 'Session signed out.');
      await cubit.close();
    });

    test('revokeAllWeb reports how many were signed out', () async {
      final cubit = SessionsCubit(repository);
      await cubit.load();
      when(() => repository.list()).thenAnswer((_) async => [phone]);

      await cubit.revokeAllWeb();

      expect(cubit.state.sessions, [phone]);
      expect(cubit.state.webSessionCount, 0);
      expect(cubit.state.message, 'Signed out 2 web sessions.');
      await cubit.close();
    });

    test('a failure keeps the list and explains', () async {
      final cubit = SessionsCubit(repository);
      await cubit.load();
      when(() => repository.revoke(any())).thenThrow(
        const ServerException(statusCode: 500, code: 'x', message: 'x'),
      );
      await cubit.revoke(itemIdB);
      expect(cubit.state.sessions, [web1, phone, web2]);
      expect(cubit.state.busy, isFalse);
      expect(cubit.state.message, 'Server error (500).');
      await cubit.close();
    });
  });

  group('ActivityCubit', () {
    late MockSessionsRepository repository;

    setUp(() => repository = MockSessionsRepository());

    test('pages through the audit log, newest first', () async {
      when(() => repository.auditLog(before: null)).thenAnswer(
        (_) async => AuditPage(
          entries: [
            auditEntry(42, 'qr_approved'),
            auditEntry(41, 'qr_created'),
          ],
          nextBefore: 41,
        ),
      );
      when(() => repository.auditLog(before: 41)).thenAnswer(
        (_) async => AuditPage(
          entries: [auditEntry(40, 'device_auth_ok')],
          nextBefore: null,
        ),
      );
      final cubit = ActivityCubit(repository);

      await cubit.load();
      expect(cubit.state.loaded, isTrue);
      expect(cubit.state.entries.map((e) => e.id), [42, 41]);
      expect(cubit.state.hasMore, isTrue);

      await cubit.loadMore();
      expect(cubit.state.entries.map((e) => e.id), [42, 41, 40]);
      expect(cubit.state.hasMore, isFalse);

      await cubit.loadMore(); // nothing more to fetch
      verify(() => repository.auditLog(before: any(named: 'before'))).called(2);
      await cubit.close();
    });

    test('an error keeps what was already loaded', () async {
      when(() => repository.auditLog(before: null)).thenAnswer(
        (_) async =>
            AuditPage(entries: [auditEntry(42, 'logout')], nextBefore: 42),
      );
      when(() => repository.auditLog(before: 42)).thenThrow(
        const ServerException(statusCode: 500, code: 'x', message: 'x'),
      );
      final cubit = ActivityCubit(repository);
      await cubit.load();
      await cubit.loadMore();
      expect(cubit.state.entries.map((e) => e.id), [42]);
      expect(cubit.state.message, 'Server error (500).');
      expect(cubit.state.hasMore, isTrue);
      await cubit.close();
    });
  });
}
