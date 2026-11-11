// Shared test doubles. Pure Dart: usable from VM tests and widget tests.
import 'dart:async';
import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/core/error/failures.dart';
import 'package:leopard_web/core/network/leopard_api.dart';
import 'package:leopard_web/core/security/key_derivation.dart';
import 'package:leopard_web/core/security/secret_clipboard.dart';
import 'package:leopard_web/core/session/vault_session.dart';
import 'package:leopard_web/features/emergency_login/domain/emergency_login_repository.dart';
import 'package:leopard_web/features/qr_login/domain/qr_login_repository.dart';
import 'package:leopard_web/features/vault/domain/vault_entry.dart';
import 'package:leopard_web/features/vault/domain/vault_repository.dart';
import 'package:mocktail/mocktail.dart';

class MockVaultRepository extends Mock implements VaultRepository {}

class MockQrLoginRepository extends Mock implements QrLoginRepository {}

class MockEmergencyLoginRepository extends Mock
    implements EmergencyLoginRepository {}

class MockLeopardApi extends Mock implements LeopardApi {}

class MockKeyDerivation extends Mock implements KeyDerivation {}

class MockSecretClipboard extends Mock implements SecretClipboard {}

const String sessionIdA = '0b0f4c58-9d5e-4b8a-8a43-0e6c1c7d1f02';
const String itemIdA = '0f8fad5b-d9cb-469f-a165-70867728950e';
const String itemIdB = '9b2e7f10-3c4d-4e5f-8a6b-7c8d9e0f1a2b';
const String itemIdC = '2d4b1b1e-6f0a-4a39-8a51-1d5f3c9f7e10';
final DateTime t0 = DateTime.utc(2026, 11, 11, 10);

Uint8List bytesOf(int length, int seed) =>
    Uint8List.fromList(List.generate(length, (i) => (seed + i * 7) & 0xff));

/// A syntactically valid session or poll token.
String tokenOf(int seed) => base64UrlEncodeNoPad(bytesOf(tokenSize, seed));

SessionGrant webGrant({String? token}) => SessionGrant(
  token: token ?? tokenOf(0x21),
  sessionId: sessionIdA,
  kind: SessionKind.web,
  idleTimeoutSeconds: 300,
);

LoginItem login(
  String title, {
  String username = 'aziz',
  String password = 'correct horse battery staple',
  List<String> urls = const ['https://example.com'],
  DateTime? updatedAt,
}) => LoginItem(
  title: title,
  username: username,
  password: password,
  urls: urls,
  createdAt: t0,
  updatedAt: updatedAt ?? t0,
);

VaultEntry entry(String id, VaultItem item, {int version = 1}) =>
    VaultEntry(id: id, version: version, item: item);

/// The vault of a signed-in browser, with fixed keys.
UnlockedVault unlockedVault({Uint8List? vaultKey, Uint8List? itemKey}) =>
    UnlockedVault(
      vaultKey: vaultKey ?? bytesOf(keySize, 0x11),
      itemKey: itemKey ?? bytesOf(keySize, 0x31),
      sessionId: sessionIdA,
      method: LoginMethod.qr,
      idleTimeout: const Duration(seconds: 300),
    );

/// A [VaultSession] signed in with a fixed vault key and its real item key.
Future<VaultSession> unlockedSession(
  LeopardCrypto crypto, {
  Uint8List? vaultKey,
}) async {
  final vk = vaultKey ?? bytesOf(keySize, 0x11);
  return VaultSession()..open(
    unlockedVault(
      vaultKey: Uint8List.fromList(vk),
      itemKey: await crypto.deriveItemKey(vk),
    ),
  );
}

/// An in-memory server for items that follows the version rules of
/// docs/api.md: `expected_version` must match, 409 with `current` when it
/// does not, 410 for tombstones, 404 for unknown ids.
///
/// Like the real API wrapper it refuses item calls without a session and
/// announces a 401 on [sessionEnded].
class FakeItemServer implements LeopardApi {
  final Map<String, RemoteItem> items = {};
  final StreamController<UnauthorizedException> ended =
      StreamController<UnauthorizedException>.broadcast();
  int _clock = 0;
  int listCalls = 0;
  int heartbeats = 0;
  int logouts = 0;

  /// Whether a session token is "held".
  bool signedIn = true;

  /// When set, every authenticated call fails with this 401 code.
  String? revokedWith;

  DateTime _tick() => t0.add(Duration(seconds: ++_clock));

  @override
  bool get hasSession => signedIn;

  @override
  Stream<UnauthorizedException> get sessionEnded => ended.stream;

  void _authenticate() {
    if (!signedIn) {
      throw const VaultLockedFailure();
    }
    final code = revokedWith;
    if (code != null) {
      final error = UnauthorizedException(
        statusCode: 401,
        code: code,
        message: 'fake: $code',
      );
      signedIn = false;
      ended.add(error);
      throw error;
    }
  }

  /// What another device would do: store [sealed] as the next version.
  void writeDirectly(String id, SealedItem sealed, int version) {
    items[id] = RemoteItem(
      id: id,
      version: version,
      updatedAt: _tick(),
      deleted: false,
      ciphertext: sealed.ciphertext,
      nonce: sealed.nonce,
    );
  }

  void deleteDirectly(String id) {
    final current = items[id]!;
    final now = _tick();
    items[id] = RemoteItem(
      id: id,
      version: current.version + 1,
      updatedAt: now,
      deleted: true,
      deletedAt: now,
    );
  }

  @override
  Future<ItemsPage> listItems({String? since}) async {
    _authenticate();
    listCalls++;
    final after = since == null ? null : DateTime.parse(since);
    final list = [
      for (final item in items.values)
        if (after == null || item.updatedAt.isAfter(after)) item,
    ]..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    return ItemsPage(
      items: list,
      serverTime: t0.add(Duration(seconds: _clock)).toIso8601String(),
    );
  }

  ItemMeta _meta(RemoteItem item) => ItemMeta(
    id: item.id,
    version: item.version,
    updatedAt: item.updatedAt,
    deleted: item.deleted,
  );

  Never _conflict(RemoteItem current) => throw ConflictException(
    statusCode: 409,
    code: 'version_conflict',
    message: 'expected_version does not match the stored version',
    current: _meta(current),
  );

  @override
  Future<ItemMeta> putItem({
    required String id,
    required SealedItem sealed,
    required int expectedVersion,
  }) async {
    _authenticate();
    final current = items[id];
    if (current == null) {
      if (expectedVersion != 0) {
        throw const NotFoundException(
          statusCode: 404,
          code: 'item_not_found',
          message: 'no such item',
        );
      }
    } else if (current.deleted) {
      throw GoneException(
        statusCode: 410,
        code: 'item_deleted',
        message: 'the item was deleted',
        current: _meta(current),
      );
    } else if (current.version != expectedVersion) {
      _conflict(current);
    }
    writeDirectly(id, sealed, expectedVersion + 1);
    return _meta(items[id]!);
  }

  @override
  Future<ItemMeta> deleteItem({
    required String id,
    required int expectedVersion,
  }) async {
    _authenticate();
    final current = items[id];
    if (current == null) {
      throw const NotFoundException(
        statusCode: 404,
        code: 'item_not_found',
        message: 'no such item',
      );
    }
    if (current.deleted) {
      throw GoneException(
        statusCode: 410,
        code: 'item_deleted',
        message: 'the item was deleted',
        current: _meta(current),
      );
    }
    if (current.version != expectedVersion) {
      _conflict(current);
    }
    deleteDirectly(id);
    return _meta(items[id]!);
  }

  @override
  Future<Heartbeat> heartbeat() async {
    _authenticate();
    heartbeats++;
    final now = _tick();
    return Heartbeat(
      sessionId: sessionIdA,
      kind: SessionKind.web,
      idleTimeoutSeconds: 300,
      expiresAt: now.add(const Duration(seconds: 300)),
      serverTime: now,
    );
  }

  @override
  Future<void> logout() async {
    if (!signedIn) return;
    logouts++;
    signedIn = false;
  }

  @override
  void clearSession() => signedIn = false;

  @override
  Future<QrSession> createQrSession({
    required Uint8List browserPub,
    Map<String, Object?>? clientInfo,
  }) => throw UnimplementedError();

  @override
  Future<QrPollResult> pollQrSession({
    required Uint8List sid,
    required String pollToken,
  }) => throw UnimplementedError();

  @override
  Future<MasterParams> masterParams() => throw UnimplementedError();

  @override
  Future<MasterLoginResult> masterLogin({
    required String totpCode,
    required Uint8List proof,
    Map<String, Object?>? clientInfo,
  }) => throw UnimplementedError();
}
