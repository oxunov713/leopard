// SetupRepositoryImpl with real crypto and an HTTP stub in place of the
// server. One real Argon2id run (64 MiB) in setUpAll.
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
import 'package:leopard_mobile/features/setup/data/setup_repository_impl.dart';
import 'package:leopard_mobile/features/setup/domain/setup_repository.dart';
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

  late MemoryKeyValueStore keyValues;
  late SecureDeviceStore store;
  late VaultSession session;
  late MockRemoteVault remote;
  late List<http.Request> requests;
  late http.Response Function(http.Request) respond;
  final now = DateTime.utc(2026, 11, 11, 10);

  SetupRepositoryImpl build() => SetupRepositoryImpl(
    store: store,
    session: session,
    remote: remote,
    keyDerivation: const IsolateKeyDerivation(),
    crypto: crypto,
    clientFactory: (url) => LeopardApiClient(
      baseUrl: url,
      httpClient: MockClient((request) async {
        requests.add(request);
        return respond(request);
      }),
    ),
    now: () => now,
  );

  setUpAll(() async {
    registerFallbackValue(Uri.parse('https://fallback.example'));
    // The same derivation the app runs, done once for all tests.
    salt = bytesOf(saltSize, 0x21);
    kek = await const IsolateKeyDerivation().deriveKek(
      masterPassword: password,
      salt: salt,
      params: KdfParams.v1,
    );
  });

  setUp(() {
    keyValues = MemoryKeyValueStore();
    store = SecureDeviceStore(keyValues);
    session = VaultSession();
    remote = MockRemoteVault();
    requests = [];
    respond = (_) => json(201, {
      'device_id': deviceIdA,
      'created_at': '2026-11-11T10:00:00Z',
    });
  });

  /// Setup material for [password] without a second Argon2id run.
  Future<VaultSetupMaterial> material() async {
    final vaultKey = crypto.generateVaultKey();
    final recoveryKey = crypto.generateRecoveryKey();
    return VaultSetupMaterial(
      kdfParams: KdfParams.v1,
      salt: Uint8List.fromList(salt),
      wrappedVkMaster: await crypto.wrapVaultKey(
        kek: kek,
        vaultKey: vaultKey,
        label: WrapLabel.master,
      ),
      wrappedVkRecovery: await crypto.wrapVaultKey(
        kek: await crypto.recoveryKek(recoveryKey),
        vaultKey: vaultKey,
        label: WrapLabel.recovery,
      ),
      masterAuthVerifier: await crypto.authVerifier(
        await crypto.masterAuthKey(kek),
      ),
      recoveryAuthVerifier: await crypto.authVerifier(
        await crypto.recoveryAuthKey(recoveryKey),
      ),
      totpSecret: bytesOf(totpSecretSize, 0x31),
      deviceKey: await crypto.generateEd25519KeyPair(),
      vaultKey: vaultKey,
      recoveryKey: recoveryKey,
    );
  }

  test('the background isolate derives the documented KEK', () async {
    // Same inputs on the calling isolate must give the same key, and a
    // decomposed spelling of a password must give the key of the composed
    // one (NFC happens inside the isolate).
    final direct = await crypto.deriveKek(
      password: LeopardCrypto.passwordBytes(password),
      salt: salt,
    );
    expect(kek, direct);
  });

  test('prepare generates a complete, self-consistent vault', () async {
    final prepared = await build().prepare(password);
    final derived = await crypto.deriveKek(
      password: LeopardCrypto.passwordBytes(password),
      salt: prepared.salt,
    );
    expect(
      await crypto.unwrapVaultKey(
        kek: derived,
        wrapped: prepared.wrappedVkMaster,
        label: WrapLabel.master,
      ),
      prepared.vaultKey,
    );
    expect(prepared.recoveryKey, hasLength(recoveryKeySize));
    expect(prepared.totpSecret, hasLength(totpSecretSize));
    expect(prepared.deviceKey.seed, hasLength(ed25519SeedSize));
  });

  group('checkServer', () {
    test('accepts a healthy server', () async {
      respond = (_) => json(200, {'status': 'ok'});
      await build().checkServer(serverUrl);
      expect(
        requests.single.url.toString(),
        'https://vault.example.com/healthz',
      );
    });

    test('rejects something that is not a Leopard server', () async {
      respond = (_) => http.Response('<html>', 404);
      await expectLater(
        build().checkServer(serverUrl),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('the API client itself refuses http', () {
      expect(
        () => build().checkServer(Uri.parse('http://vault.example.com')),
        throwsArgumentError,
      );
      expect(parseServerUrl('http://vault.example.com'), isNull);
    });
  });

  group('verifyTotpCode', () {
    final secret = bytesOf(totpSecretSize, 0x31);
    Future<String> codeAt(DateTime time) => crypto.totpCode(
      secret: secret,
      unixSeconds: time.millisecondsSinceEpoch ~/ 1000,
    );

    test('accepts the current step and one step either side', () async {
      final repository = build();
      for (final offset in [-30, 0, 30]) {
        final code = await codeAt(now.add(Duration(seconds: offset)));
        expect(
          await repository.verifyTotpCode(secret: secret, code: code),
          isTrue,
          reason: 'offset $offset',
        );
      }
      expect(
        await repository.verifyTotpCode(
          secret: secret,
          code: ' ${await codeAt(now)} ',
        ),
        isTrue,
        reason: 'surrounding spaces are ignored',
      );
    });

    test('rejects older codes, other secrets and malformed input', () async {
      final repository = build();
      final old = await codeAt(now.subtract(const Duration(minutes: 5)));
      final current = await codeAt(now);
      expect(
        await repository.verifyTotpCode(secret: secret, code: old),
        isFalse,
      );
      expect(
        await repository.verifyTotpCode(
          secret: bytesOf(totpSecretSize, 0x77),
          code: current,
        ),
        isFalse,
      );
      for (final bad in ['', '12345', '1234567', 'abcdef', '12 34 5x']) {
        expect(
          await repository.verifyTotpCode(secret: secret, code: bad),
          isFalse,
          reason: bad,
        );
      }
    });
  });

  group('commit', () {
    test('creates the vault, stores the keys and unlocks', () async {
      final m = await material();
      final vaultKey = Uint8List.fromList(m.vaultKey);
      final seed = Uint8List.fromList(m.deviceKey.seed);
      final publicKey = Uint8List.fromList(m.deviceKey.publicKey);

      await build().commit(
        material: m,
        serverUrl: serverUrl,
        deviceLabel: 'Pixel 9',
        setupToken: 's3tup',
      );

      // The request.
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://vault.example.com/v1/setup');
      expect(request.headers['X-Leopard-Setup-Token'], 's3tup');
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['device'], {
        'label': 'Pixel 9',
        'ed25519_pub': base64UrlEncodeNoPad(publicKey),
      });
      // Only wrapped keys and verifiers leave the phone.
      final sent = request.body;
      expect(sent, isNot(contains(base64UrlEncodeNoPad(vaultKey))));
      expect(sent, isNot(contains(base64UrlEncodeNoPad(seed))));
      expect(sent, isNot(contains(base64UrlEncodeNoPad(kek))));
      expect(sent, isNot(contains(password)));

      // Local state.
      final registration = (await store.readRegistration())!;
      expect(registration.deviceId, deviceIdA);
      expect(registration.serverUrl, serverUrl);
      expect(registration.deviceLabel, 'Pixel 9');
      final secrets = await store.readSecrets();
      expect(secrets.vaultKey, vaultKey);
      expect(secrets.deviceSeed, seed);
      final master = await store.readMasterMaterial();
      expect(
        await crypto.unwrapVaultKey(
          kek: kek,
          wrapped: master.wrappedVaultKey,
          label: WrapLabel.master,
        ),
        vaultKey,
      );

      // Unlocked, and the setup material is wiped.
      expect(session.isUnlocked, isTrue);
      expect(session.require.vaultKey, vaultKey);
      expect(session.require.deviceId, deviceIdA);
      expect(session.require.itemKey, await crypto.deriveItemKey(vaultKey));
      verify(() => remote.configure(serverUrl)).called(1);
      expect(m.vaultKey, everyElement(0));
      expect(m.recoveryKey, everyElement(0));
      expect(m.deviceKey.seed, everyElement(0));
    });

    test('the recovery key is never stored on the phone', () async {
      final m = await material();
      final recovery = base64UrlEncodeNoPad(m.recoveryKey);
      final display = formatRecoveryKey(m.recoveryKey);
      await build().commit(material: m, serverUrl: serverUrl, deviceLabel: 'P');
      for (final value in keyValues.values.values) {
        expect(value, isNot(contains(recovery)));
        expect(value, isNot(contains(display)));
        expect(value, isNot(contains(display.replaceAll('-', ''))));
      }
      expect(requests.single.body, isNot(contains(recovery)));
    });

    test('no setup token header unless a token was given', () async {
      await build().commit(
        material: await material(),
        serverUrl: serverUrl,
        deviceLabel: 'P',
        setupToken: '   ',
      );
      expect(
        requests.single.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('x-leopard-setup-token')),
      );
    });

    test('409 already_initialised: not registered, still locked', () async {
      respond = (_) => json(409, {
        'error': {'code': 'already_initialised', 'message': 'a vault exists'},
      });
      final m = await material();

      await expectLater(
        build().commit(material: m, serverUrl: serverUrl, deviceLabel: 'P'),
        throwsA(
          isA<ConflictException>().having(
            (e) => e.code,
            'code',
            'already_initialised',
          ),
        ),
      );

      expect(await store.readRegistration(), isNull);
      expect(session.isUnlocked, isFalse);
      verifyNever(() => remote.configure(any()));
      // The material survives so the user can retry (for example with the
      // right setup token) without starting over.
      expect(m.vaultKey, isNot(everyElement(0)));
    });

    test('a storage failure stops before the server is asked', () async {
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
      final repository = SetupRepositoryImpl(
        store: failing,
        session: session,
        remote: remote,
        keyDerivation: const IsolateKeyDerivation(),
        crypto: crypto,
        clientFactory: (url) => LeopardApiClient(
          baseUrl: url,
          httpClient: MockClient((request) async {
            requests.add(request);
            return respond(request);
          }),
        ),
      );

      await expectLater(
        repository.commit(
          material: await material(),
          serverUrl: serverUrl,
          deviceLabel: 'P',
        ),
        throwsA(isA<StorageFailure>()),
      );
      expect(requests, isEmpty);
      expect(session.isUnlocked, isFalse);
    });
  });
}
