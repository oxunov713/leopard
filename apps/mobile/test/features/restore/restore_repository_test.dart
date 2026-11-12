// RestoreRepositoryImpl with real crypto and an HTTP stub in place of the
// server. One real Argon2id run (64 MiB) in setUpAll; the repository gets the
// result through a KeyDerivation double.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/core/error/failures.dart';
import 'package:leopard_mobile/core/security/key_derivation.dart';
import 'package:leopard_mobile/core/session/vault_session.dart';
import 'package:leopard_mobile/core/storage/device_store.dart';
import 'package:leopard_mobile/features/restore/data/restore_repository_impl.dart';
import 'package:leopard_mobile/features/restore/domain/restore_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

const password = 'granite-walrus-47-lantern-oboe';

http.Response json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  final crypto = newLeopardCrypto();
  late Uint8List kek;
  late Uint8List salt;

  late Uint8List recoveryKey;
  late Uint8List vaultKey;
  late Uint8List wrappedVkRecovery;

  late MemoryKeyValueStore keyValues;
  late SecureDeviceStore store;
  late VaultSession session;
  late MockRemoteVault remote;
  late MockKeyDerivation keyDerivation;
  late List<http.Request> requests;
  late http.Response Function(http.Request) respond;
  late http.Response Function() masterParams;

  /// How many requests had been made when the KEK was derived.
  late List<int> derivedAfterRequests;

  RestoreRepositoryImpl build() => RestoreRepositoryImpl(
    store: store,
    session: session,
    remote: remote,
    keyDerivation: keyDerivation,
    crypto: crypto,
    clientFactory: (url) => LeopardApiClient(
      baseUrl: url,
      httpClient: MockClient((request) async {
        requests.add(request);
        return respond(request);
      }),
    ),
  );

  Map<String, Object?> registered() => {
    'device_id': deviceIdA,
    'wrapped_vk_recovery': base64UrlEncodeNoPad(wrappedVkRecovery),
    'kdf_params': KdfParams.v1.toJson(),
    'salt': base64UrlEncodeNoPad(salt),
  };

  /// A healthy server with the vault's KDF parameters that answers
  /// register-device with [register].
  http.Response Function(http.Request) server(
    http.Response Function() register,
  ) {
    return (request) {
      if (request.url.path == '/healthz') {
        return json(200, {'status': 'ok'});
      }
      if (request.url.path == '/v1/auth/master/params') {
        return masterParams();
      }
      return register();
    };
  }

  bool registerWasCalled() => requests.any(
    (request) => request.url.path == '/v1/recovery/register-device',
  );

  setUpAll(() async {
    registerFallbackValue(Uri.parse('https://fallback.example'));
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(KdfParams.v1);
    salt = bytesOf(saltSize, 0x21);
    kek = await const IsolateKeyDerivation().deriveKek(
      masterPassword: password,
      salt: salt,
      params: KdfParams.v1,
    );
  });

  setUp(() async {
    recoveryKey = crypto.generateRecoveryKey();
    vaultKey = crypto.generateVaultKey();
    wrappedVkRecovery = await crypto.wrapVaultKey(
      kek: await crypto.recoveryKek(recoveryKey),
      vaultKey: vaultKey,
      label: WrapLabel.recovery,
    );
    keyValues = MemoryKeyValueStore();
    store = SecureDeviceStore(keyValues);
    session = VaultSession();
    remote = MockRemoteVault();
    keyDerivation = MockKeyDerivation();
    when(
      () => keyDerivation.deriveKek(
        masterPassword: any(named: 'masterPassword'),
        salt: any(named: 'salt'),
        params: any(named: 'params'),
      ),
    ).thenAnswer((_) async {
      derivedAfterRequests.add(requests.length);
      return Uint8List.fromList(kek);
    });
    derivedAfterRequests = [];
    requests = [];
    masterParams = () => json(200, {
      'kdf_params': KdfParams.v1.toJson(),
      'salt': base64UrlEncodeNoPad(salt),
    });
    respond = server(() => json(201, registered()));
  });

  Future<void> restore(Uint8List key) => build().restore(
    serverUrl: serverUrl,
    deviceLabel: 'New phone',
    recoveryKey: key,
    masterPassword: password,
  );

  test('registers a new device key with the recovery proof, stores the keys '
      'like setup does and opens the vault on request', () async {
    final key = Uint8List.fromList(recoveryKey);
    await restore(key);

    // The requests, and the slow KDF before the irreversible one.
    expect(requests.map((r) => r.url.path), [
      '/healthz',
      '/v1/auth/master/params',
      '/v1/recovery/register-device',
    ]);
    expect(derivedAfterRequests, [2]);
    final request = requests.last;
    expect(request.method, 'POST');
    expect(
      request.url.toString(),
      'https://vault.example.com/v1/recovery/register-device',
    );
    final body = jsonDecode(request.body) as Map<String, Object?>;
    expect(
      body['proof'],
      base64UrlEncodeNoPad(await crypto.recoveryAuthKey(recoveryKey)),
    );
    final device = body['device']! as Map<String, Object?>;
    expect(device['label'], 'New phone');

    // Local state, in the same places setup uses.
    final registration = (await store.readRegistration())!;
    expect(registration.deviceId, deviceIdA);
    expect(registration.serverUrl, serverUrl);
    expect(registration.deviceLabel, 'New phone');
    final secrets = await store.readSecrets();
    expect(secrets.vaultKey, vaultKey);
    final pair = await crypto.ed25519KeyPairFromSeed(secrets.deviceSeed);
    expect(device['ed25519_pub'], base64UrlEncodeNoPad(pair.publicKey));
    final master = await store.readMasterMaterial();
    expect(master.salt, salt);
    expect(master.kdfParams, KdfParams.v1);
    expect(
      await crypto.unwrapVaultKey(
        kek: kek,
        wrapped: master.wrappedVaultKey,
        label: WrapLabel.master,
      ),
      vaultKey,
      reason: 'the master-password fallback opens the restored vault',
    );
    verify(
      () => keyDerivation.deriveKek(
        masterPassword: password,
        salt: salt,
        params: KdfParams.v1,
      ),
    ).called(1);

    // Nothing secret left the phone; the recovery key is wiped.
    final sent = request.body;
    expect(sent, isNot(contains(base64UrlEncodeNoPad(vaultKey))));
    expect(sent, isNot(contains(base64UrlEncodeNoPad(recoveryKey))));
    expect(sent, isNot(contains(base64UrlEncodeNoPad(secrets.deviceSeed))));
    expect(sent, isNot(contains(password)));
    expect(key, everyElement(0));

    // Still locked until the user has read the notice.
    expect(session.isUnlocked, isFalse);
    await build().openRestoredVault();
    expect(session.isUnlocked, isTrue);
    expect(session.require.deviceId, deviceIdA);
    expect(session.require.vaultKey, vaultKey);
    expect(session.require.itemKey, await crypto.deriveItemKey(vaultKey));
    expect(session.require.deviceSeed, secrets.deviceSeed);
    verify(() => remote.configure(serverUrl)).called(1);
  });

  test('the recovery key is never stored on the phone', () async {
    final recovery = base64UrlEncodeNoPad(recoveryKey);
    final display = formatRecoveryKey(recoveryKey);
    await restore(Uint8List.fromList(recoveryKey));
    for (final value in keyValues.values.values) {
      expect(value, isNot(contains(recovery)));
      expect(value, isNot(contains(display)));
      expect(value, isNot(contains(display.replaceAll('-', ''))));
    }
  });

  test('401 invalid_credentials: nothing stored, key wiped, and not '
      'reported as a half-finished restore', () async {
    final refused = json(401, {
      'error': {'code': 'invalid_credentials', 'message': 'invalid'},
    });
    respond = server(() => refused);
    final key = Uint8List.fromList(recoveryKey);

    await expectLater(
      restore(key),
      throwsA(
        isA<UnauthorizedException>().having(
          (e) => e.code,
          'code',
          'invalid_credentials',
        ),
      ),
    );

    expect(keyValues.values, isEmpty);
    expect(await store.readRegistration(), isNull);
    expect(session.isUnlocked, isFalse);
    expect(key, everyElement(0));
  });

  test('a KDF failure stops before the server is asked', () async {
    when(
      () => keyDerivation.deriveKek(
        masterPassword: any(named: 'masterPassword'),
        salt: any(named: 'salt'),
        params: any(named: 'params'),
      ),
    ).thenThrow(StateError('isolate died'));
    final key = Uint8List.fromList(recoveryKey);

    await expectLater(restore(key), throwsA(isA<StateError>()));
    expect(registerWasCalled(), isFalse);
    expect(keyValues.values, isEmpty);
    expect(key, everyElement(0));
  });

  test('master params missing: stops before the server is asked', () async {
    masterParams = () => json(404, {
      'error': {'code': 'not_initialised', 'message': 'no vault'},
    });

    await expectLater(
      restore(Uint8List.fromList(recoveryKey)),
      throwsA(isA<NotFoundException>()),
    );
    expect(registerWasCalled(), isFalse);
    verifyNever(
      () => keyDerivation.deriveKek(
        masterPassword: any(named: 'masterPassword'),
        salt: any(named: 'salt'),
        params: any(named: 'params'),
      ),
    );
  });

  test('a different salt from register-device: incomplete', () async {
    final otherSalt = base64UrlEncodeNoPad(bytesOf(saltSize, 0x55));
    respond = server(() => json(201, {...registered(), 'salt': otherSalt}));

    await expectLater(
      restore(Uint8List.fromList(recoveryKey)),
      throwsA(
        isA<RestoreIncompleteFailure>().having(
          (e) => e.cause,
          'cause',
          isA<ValidationFailure>(),
        ),
      ),
    );
    expect(keyValues.values, isEmpty);
    expect(session.isUnlocked, isFalse);
  });

  test('429 rate_limited carries Retry-After', () async {
    final limited = http.Response(
      '{"error":{"code":"rate_limited","message":"slow down"}}',
      429,
      headers: {'content-type': 'application/json', 'retry-after': '1800'},
    );
    respond = server(() => limited);
    final key = Uint8List.fromList(recoveryKey);

    await expectLater(
      restore(key),
      throwsA(
        isA<RateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(minutes: 30),
        ),
      ),
    );
    expect(keyValues.values, isEmpty);
    expect(key, everyElement(0));
  });

  test('not a Leopard server: no recovery attempt is spent', () async {
    respond = (_) => http.Response('<html>', 404);
    final key = Uint8List.fromList(recoveryKey);

    await expectLater(restore(key), throwsA(isA<ValidationFailure>()));
    expect(requests.single.url.path, '/healthz');
    expect(key, everyElement(0));
  });

  test('network failure: nothing stored, key wiped', () async {
    respond = server(() => throw http.ClientException('connection reset'));
    final key = Uint8List.fromList(recoveryKey);

    await expectLater(restore(key), throwsA(isA<http.ClientException>()));
    expect(keyValues.values, isEmpty);
    expect(key, everyElement(0));
  });

  test('a wrapped key that does not open with the recovery key is refused, '
      'and nothing is stored', () async {
    wrappedVkRecovery = await crypto.wrapVaultKey(
      kek: bytesOf(keySize, 0x99),
      vaultKey: vaultKey,
      label: WrapLabel.recovery,
    );

    await expectLater(
      restore(Uint8List.fromList(recoveryKey)),
      throwsA(
        isA<RestoreIncompleteFailure>().having(
          (e) => e.cause,
          'cause',
          isA<DecryptException>(),
        ),
      ),
    );
    expect(keyValues.values, isEmpty);
    expect(session.isUnlocked, isFalse);
  });

  test('storage failure after register-device: incomplete', () async {
    final failing = MockDeviceStore();
    registerFallbackValue(
      DeviceSecrets(vaultKey: Uint8List(0), deviceSeed: Uint8List(0)),
    );
    registerFallbackValue(
      MasterUnlockMaterial(
        wrappedVaultKey: Uint8List(0),
        salt: Uint8List(0),
        kdfParams: KdfParams.v1,
      ),
    );
    when(
      () => failing.saveSecrets(
        secrets: any(named: 'secrets'),
        masterMaterial: any(named: 'masterMaterial'),
      ),
    ).thenThrow(const StorageFailure());
    final repository = RestoreRepositoryImpl(
      store: failing,
      session: session,
      remote: remote,
      keyDerivation: keyDerivation,
      crypto: crypto,
      clientFactory: (url) => LeopardApiClient(
        baseUrl: url,
        httpClient: MockClient((request) async => respond(request)),
      ),
    );

    await expectLater(
      repository.restore(
        serverUrl: serverUrl,
        deviceLabel: 'P',
        recoveryKey: Uint8List.fromList(recoveryKey),
        masterPassword: password,
      ),
      throwsA(
        isA<RestoreIncompleteFailure>().having(
          (e) => e.cause,
          'cause',
          isA<StorageFailure>(),
        ),
      ),
    );
    expect(session.isUnlocked, isFalse);
  });

  test('openRestoredVault refuses a phone that is not set up', () async {
    await expectLater(
      build().openRestoredVault(),
      throwsA(isA<StorageFailure>()),
    );
    expect(session.isUnlocked, isFalse);
  });
}
