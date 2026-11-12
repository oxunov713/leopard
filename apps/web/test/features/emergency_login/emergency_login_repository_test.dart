// EmergencyLoginRepositoryImpl with the real crypto of leopard_core. The
// server half (compare SHA-256 of the proof, release the wrapped key) is
// played by the test.
import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/core/error/failures.dart';
import 'package:leopard_web/core/security/key_derivation.dart';
import 'package:leopard_web/core/session/vault_session.dart';
import 'package:leopard_web/features/emergency_login/data/emergency_login_repository_impl.dart';
import 'package:leopard_web/features/emergency_login/domain/emergency_login_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

const invalidCredentials = UnauthorizedException(
  statusCode: 401,
  code: 'invalid_credentials',
  message: 'x',
);

void main() {
  final crypto = LeopardCrypto();
  final vaultKey = bytesOf(keySize, 0x11);
  final salt = bytesOf(saltSize, 0x10);
  final rightKek = bytesOf(keySize, 0x71);
  final wrongKek = bytesOf(keySize, 0x72);

  late MockLeopardApi api;
  late MockKeyDerivation keyDerivation;
  late VaultSession session;
  late EmergencyLoginRepositoryImpl repository;
  late Uint8List verifier;
  late Uint8List wrapped;
  late List<Uint8List> derivedKeks;
  String? sentCode;

  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(KdfParams.v1);
  });

  setUp(() async {
    api = MockLeopardApi();
    keyDerivation = MockKeyDerivation();
    session = VaultSession();
    derivedKeks = [];
    sentCode = null;
    verifier = await crypto.authVerifier(await crypto.masterAuthKey(rightKek));
    wrapped = await crypto.wrapVaultKey(
      kek: rightKek,
      vaultKey: vaultKey,
      label: WrapLabel.master,
    );
    repository = EmergencyLoginRepositoryImpl(
      api: api,
      session: session,
      crypto: crypto,
      keyDerivation: keyDerivation,
      clientInfo: () => {'browser': 'Leopard web'},
    );

    when(() => api.masterParams()).thenAnswer(
      (_) async => MasterParams(kdfParams: KdfParams.v1, salt: salt),
    );
    when(() => api.logout()).thenAnswer((_) async {});
    // "hunter2 hunter2" is the right password; anything else derives a
    // different key.
    when(
      () => keyDerivation.deriveKek(
        masterPassword: any(named: 'masterPassword'),
        salt: any(named: 'salt'),
        params: any(named: 'params'),
      ),
    ).thenAnswer((invocation) async {
      final password = invocation.namedArguments[#masterPassword] as String;
      final kek = Uint8List.fromList(
        password == 'hunter2 hunter2' ? rightKek : wrongKek,
      );
      derivedKeks.add(kek);
      return kek;
    });
    // The server: SHA-256(proof) must equal the stored verifier, and the
    // code must be the current one.
    when(
      () => api.masterLogin(
        totpCode: any(named: 'totpCode'),
        proof: any(named: 'proof'),
        clientInfo: any(named: 'clientInfo'),
      ),
    ).thenAnswer((invocation) async {
      final proof = invocation.namedArguments[#proof] as Uint8List;
      final code = invocation.namedArguments[#totpCode] as String;
      sentCode = code;
      final ok = constantTimeEquals(await crypto.authVerifier(proof), verifier);
      if (!ok || code != '492039') {
        throw invalidCredentials;
      }
      return MasterLoginResult(session: webGrant(), wrappedVkMaster: wrapped);
    });
  });

  test('right password and code: the vault key is unwrapped here', () async {
    final phases = <EmergencyLoginPhase>[];
    await repository.login(
      masterPassword: 'hunter2 hunter2',
      totpCode: '492 039',
      onPhase: phases.add,
    );

    expect(phases, EmergencyLoginPhase.values);
    final vault = session.require;
    expect(vault.vaultKey, vaultKey);
    expect(vault.itemKey, await crypto.deriveItemKey(vaultKey));
    expect(vault.method, LoginMethod.emergency);
    expect(vault.sessionId, sessionIdA);
    expect(sentCode, '492039', reason: 'spaces are removed');
    // The KEK does not outlive the login.
    expect(derivedKeks.single, everyElement(0));
    verify(
      () => keyDerivation.deriveKek(
        masterPassword: 'hunter2 hunter2',
        salt: salt,
        params: KdfParams.v1,
      ),
    ).called(1);
  });

  test(
    'the proof is the master auth key, never the KEK or the password',
    () async {
      await repository.login(
        masterPassword: 'hunter2 hunter2',
        totpCode: '492039',
      );
      final proof =
          verify(
                () => api.masterLogin(
                  totpCode: any(named: 'totpCode'),
                  proof: captureAny(named: 'proof'),
                  clientInfo: any(named: 'clientInfo'),
                ),
              ).captured.single
              as Uint8List;
      // The repository wiped its copy after the call; what the server saw is
      // checked inside the stub. Here: it was 32 bytes and is now zeroed.
      expect(proof, hasLength(keySize));
      expect(proof, everyElement(0));
    },
  );

  test('wrong password: 401, nothing unlocked, key wiped', () async {
    await expectLater(
      repository.login(masterPassword: 'wrong', totpCode: '492039'),
      throwsA(
        isA<UnauthorizedException>().having(
          (e) => e.code,
          'code',
          'invalid_credentials',
        ),
      ),
    );
    expect(session.isUnlocked, isFalse);
    expect(derivedKeks.single, everyElement(0));
  });

  test('wrong or replayed code: the same 401', () async {
    await expectLater(
      repository.login(masterPassword: 'hunter2 hunter2', totpCode: '000000'),
      throwsA(isA<UnauthorizedException>()),
    );
    expect(session.isUnlocked, isFalse);
  });

  test('429 is passed on with Retry-After', () async {
    when(
      () => api.masterLogin(
        totpCode: any(named: 'totpCode'),
        proof: any(named: 'proof'),
        clientInfo: any(named: 'clientInfo'),
      ),
    ).thenThrow(
      const RateLimitedException(
        statusCode: 429,
        code: 'rate_limited',
        message: 'x',
        retryAfter: Duration(seconds: 600),
      ),
    );
    await expectLater(
      repository.login(masterPassword: 'hunter2 hunter2', totpCode: '492039'),
      throwsA(
        isA<RateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 600),
        ),
      ),
    );
  });

  test('input is checked before anything is sent', () async {
    await expectLater(
      repository.login(masterPassword: '', totpCode: '492039'),
      throwsA(isA<ValidationFailure>()),
    );
    for (final code in ['', '12345', '1234567', 'abcdef']) {
      await expectLater(
        repository.login(masterPassword: 'hunter2 hunter2', totpCode: code),
        throwsA(isA<ValidationFailure>()),
      );
    }
    verifyNever(() => api.masterParams());
    verifyNever(
      () => keyDerivation.deriveKek(
        masterPassword: any(named: 'masterPassword'),
        salt: any(named: 'salt'),
        params: any(named: 'params'),
      ),
    );
  });

  test('the KDF parameters are fetched once per page', () async {
    for (var i = 0; i < 3; i++) {
      await expectLater(
        repository.login(masterPassword: 'wrong', totpCode: '492039'),
        throwsA(isA<UnauthorizedException>()),
      );
    }
    verify(() => api.masterParams()).called(1);
  });

  test('no vault on the server', () async {
    when(() => api.masterParams()).thenThrow(
      const NotFoundException(
        statusCode: 404,
        code: 'not_initialised',
        message: 'x',
      ),
    );
    await expectLater(
      repository.login(masterPassword: 'hunter2 hunter2', totpCode: '492039'),
      throwsA(isA<NotFoundException>()),
    );
    verifyNever(
      () => keyDerivation.deriveKek(
        masterPassword: any(named: 'masterPassword'),
        salt: any(named: 'salt'),
        params: any(named: 'params'),
      ),
    );
  });

  test('a wrapped key that does not open: session revoked, nothing '
      'unlocked', () async {
    // A server that accepts the proof but returns a blob wrapped under
    // another key.
    wrapped = await crypto.wrapVaultKey(
      kek: wrongKek,
      vaultKey: vaultKey,
      label: WrapLabel.master,
    );
    await expectLater(
      repository.login(masterPassword: 'hunter2 hunter2', totpCode: '492039'),
      throwsA(isA<ServerMismatchFailure>()),
    );
    expect(session.isUnlocked, isFalse);
    verify(() => api.logout()).called(1);
  });

  test(
    'a key wrapped for recovery is not accepted as the master copy',
    () async {
      wrapped = await crypto.wrapVaultKey(
        kek: rightKek,
        vaultKey: vaultKey,
        label: WrapLabel.recovery,
      );
      await expectLater(
        repository.login(masterPassword: 'hunter2 hunter2', totpCode: '492039'),
        throwsA(isA<ServerMismatchFailure>()),
      );
    },
  );

  test(
    'end to end with the real Argon2id: NFC forms of a password agree',
    () async {
      const composed = 'pésswörd-й';
      const decomposed = 'pésswörd-й';
      final inline = InlineKeyDerivation(crypto);
      final a = await inline.deriveKek(
        masterPassword: composed,
        salt: salt,
        params: KdfParams.v1,
      );
      final b = await inline.deriveKek(
        masterPassword: decomposed,
        salt: salt,
        params: KdfParams.v1,
      );
      expect(a, hasLength(keySize));
      expect(a, b);
      expect(
        a,
        await crypto.deriveKek(
          password: LeopardCrypto.passwordBytes(composed),
          salt: salt,
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
