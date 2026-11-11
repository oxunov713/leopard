// Shared test doubles. Pure Dart: usable from VM tests and widget tests.
import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/core/network/remote_vault.dart';
import 'package:leopard_mobile/core/security/device_authenticator.dart';
import 'package:leopard_mobile/core/security/key_derivation.dart';
import 'package:leopard_mobile/core/security/secret_clipboard.dart';
import 'package:leopard_mobile/core/session/vault_session.dart';
import 'package:leopard_mobile/core/storage/device_store.dart';
import 'package:leopard_mobile/core/storage/secure_key_value_store.dart';
import 'package:leopard_mobile/features/qr_approve/domain/qr_login_repository.dart';
import 'package:leopard_mobile/features/sessions/domain/sessions_repository.dart';
import 'package:leopard_mobile/features/setup/domain/setup_repository.dart';
import 'package:leopard_mobile/features/unlock/domain/unlock_repository.dart';
import 'package:leopard_mobile/features/vault/domain/vault_entry.dart';
import 'package:leopard_mobile/features/vault/domain/vault_repository.dart';
import 'package:mocktail/mocktail.dart';

class MockSetupRepository extends Mock implements SetupRepository {}

class MockUnlockRepository extends Mock implements UnlockRepository {}

class MockVaultRepository extends Mock implements VaultRepository {}

class MockQrLoginRepository extends Mock implements QrLoginRepository {}

class MockSessionsRepository extends Mock implements SessionsRepository {}

class MockDeviceStore extends Mock implements DeviceStore {}

class MockRemoteVault extends Mock implements RemoteVault {}

class MockDeviceAuthenticator extends Mock implements DeviceAuthenticator {}

class MockKeyDerivation extends Mock implements KeyDerivation {}

class MockSecretClipboard extends Mock implements SecretClipboard {}

const String deviceIdA = '7c9e6679-7425-40de-944b-e07fc1f90ae7';
const String itemIdA = '0f8fad5b-d9cb-469f-a165-70867728950e';
const String itemIdB = '9b2e7f10-3c4d-4e5f-8a6b-7c8d9e0f1a2b';
const String itemIdC = '2d4b1b1e-6f0a-4a39-8a51-1d5f3c9f7e10';
final Uri serverUrl = Uri.parse('https://vault.example.com');
final DateTime t0 = DateTime.utc(2026, 11, 11, 10);

Uint8List bytesOf(int length, int seed) =>
    Uint8List.fromList(List.generate(length, (i) => (seed + i * 7) & 0xff));

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

/// A [SecureKeyValueStore] in a map.
class MemoryKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> deleteAll() async => values.clear();
}

/// A [VaultSession] unlocked with fixed keys.
Future<VaultSession> unlockedSession(
  LeopardCrypto crypto, {
  Uint8List? vaultKey,
  Uint8List? deviceSeed,
}) async {
  final vk = vaultKey ?? bytesOf(keySize, 0x11);
  return VaultSession()..open(
    UnlockedVault(
      deviceId: deviceIdA,
      vaultKey: Uint8List.fromList(vk),
      itemKey: await crypto.deriveItemKey(vk),
      deviceSeed: Uint8List.fromList(
        deviceSeed ?? bytesOf(ed25519SeedSize, 0x51),
      ),
    ),
  );
}

/// An in-memory server for items that follows the version rules of
/// docs/api.md: `expected_version` must match, 409 with `current` when it
/// does not, 410 for tombstones, 404 for unknown ids.
class FakeItemServer implements RemoteVault {
  final Map<String, RemoteItem> items = {};
  int _clock = 0;
  int listCalls = 0;

  DateTime _tick() => t0.add(Duration(seconds: ++_clock));

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
  void configure(Uri serverUrl) {}

  @override
  void forgetSession() {}

  @override
  Future<QrDetails> qrDetails(Uint8List sid) => throw UnimplementedError();

  @override
  Future<QrApproveResult> approveQr({
    required Uint8List sid,
    required QrApproval approval,
  }) => throw UnimplementedError();

  @override
  Future<void> rejectQr(Uint8List sid) => throw UnimplementedError();

  @override
  Future<List<SessionInfo>> listSessions() => throw UnimplementedError();

  @override
  Future<void> revokeSession(String sessionId) => throw UnimplementedError();

  @override
  Future<AuditPage> auditLog({int limit = 100, int? before}) =>
      throw UnimplementedError();
}
