import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/features/setup/domain/setup_repository.dart';
import 'package:leopard_mobile/features/setup/presentation/setup_cubit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

const strongPassword = 'granite-walrus-47-lantern-oboe';

/// Setup material with fixed bytes; no Argon2id needed for cubit tests.
VaultSetupMaterial fakeMaterial() => VaultSetupMaterial(
  kdfParams: KdfParams.v1,
  salt: bytesOf(saltSize, 1),
  wrappedVkMaster: bytesOf(wrappedVkSize, 2),
  wrappedVkRecovery: bytesOf(wrappedVkSize, 3),
  masterAuthVerifier: bytesOf(keySize, 4),
  recoveryAuthVerifier: bytesOf(keySize, 5),
  totpSecret: bytesOf(totpSecretSize, 6),
  deviceKey: Ed25519KeyPair(
    seed: bytesOf(ed25519SeedSize, 7),
    publicKey: bytesOf(ed25519PublicKeySize, 8),
  ),
  vaultKey: bytesOf(keySize, 9),
  recoveryKey: bytesOf(recoveryKeySize, 10),
);

void main() {
  late MockSetupRepository repository;
  late VaultSetupMaterial material;
  late String recoveryKey;
  late List<String> groups;

  setUpAll(() {
    registerFallbackValue(Uri.parse('https://fallback.example'));
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(fakeMaterial());
  });

  setUp(() {
    repository = MockSetupRepository();
    material = fakeMaterial();
    recoveryKey = formatRecoveryKey(material.recoveryKey);
    groups = recoveryKey.split('-');
    when(() => repository.checkServer(any())).thenAnswer((_) async {});
    when(() => repository.prepare(any())).thenAnswer((_) async => material);
    when(
      () => repository.verifyTotpCode(
        secret: any(named: 'secret'),
        code: any(named: 'code'),
      ),
    ).thenAnswer((_) async => true);
    when(
      () => repository.commit(
        material: any(named: 'material'),
        serverUrl: any(named: 'serverUrl'),
        deviceLabel: any(named: 'deviceLabel'),
        setupToken: any(named: 'setupToken'),
      ),
    ).thenAnswer((_) async {});
  });

  // Always asks for groups 2 and 5 (indexes 1 and 4).
  SetupCubit build() => SetupCubit(repository, pickChallenge: (_) => [1, 4]);

  Future<void> toPassword(SetupCubit cubit, {String token = ''}) =>
      cubit.submitServer(
        serverUrl: 'https://vault.example.com',
        deviceLabel: 'Pixel 9',
        setupToken: token,
      );

  Future<void> toRecoveryKey(SetupCubit cubit, {String token = ''}) async {
    await toPassword(cubit, token: token);
    await cubit.submitPassword(
      password: strongPassword,
      confirmation: strongPassword,
    );
  }

  Future<void> toTotp(SetupCubit cubit, {String token = ''}) async {
    await toRecoveryKey(cubit, token: token);
    cubit
      ..acknowledgeRecoveryKey(true)
      ..continueFromRecoveryKey()
      ..submitRecoveryCheck([groups[1], groups[4]]);
  }

  group('server address', () {
    for (final bad in [
      '',
      'vault.example.com',
      'http://vault.example.com',
      'ftp://vault.example.com',
      'https://',
      'https://vault.example.com/?x=1',
      'https://user:pw@vault.example.com',
    ]) {
      test('rejects "$bad" without contacting anything', () async {
        final cubit = build();
        await cubit.submitServer(serverUrl: bad, deviceLabel: 'Pixel');
        expect(cubit.state.step, SetupStep.server);
        expect(cubit.state.error, contains('https://'));
        verifyNever(() => repository.checkServer(any()));
        await cubit.close();
      });
    }

    blocTest<SetupCubit, SetupState>(
      'https address that answers moves on to the password',
      build: build,
      act: toPassword,
      expect: () => [
        const SetupState(busy: true),
        const SetupState(step: SetupStep.password),
      ],
      verify: (_) => verify(
        () => repository.checkServer(Uri.parse('https://vault.example.com')),
      ).called(1),
    );

    test('needs a device name', () async {
      final cubit = build();
      await cubit.submitServer(
        serverUrl: 'https://vault.example.com',
        deviceLabel: '   ',
      );
      expect(cubit.state.step, SetupStep.server);
      expect(cubit.state.error, isNotNull);
      await cubit.close();
    });

    test('an unreachable server keeps the user on the first step', () async {
      when(() => repository.checkServer(any())).thenThrow(
        const ServerException(statusCode: 502, code: 'x', message: 'x'),
      );
      final cubit = build();
      await toPassword(cubit);
      expect(cubit.state.step, SetupStep.server);
      expect(cubit.state.busy, isFalse);
      expect(cubit.state.error, 'Server error (502).');
      await cubit.close();
    });
  });

  group('master password', () {
    test('the strength meter follows the typed password', () async {
      final cubit = build();
      await toPassword(cubit);

      cubit.passwordChanged('password');
      expect(cubit.state.passwordProblem, isNotNull);

      cubit.passwordChanged(strongPassword);
      expect(
        cubit.state.passwordBits,
        greaterThan(MasterPasswordPolicy.minBits),
      );
      expect(cubit.state.passwordProblem, isNull);

      cubit.passwordChanged('');
      expect(cubit.state.passwordBits, 0);
      expect(cubit.state.passwordProblem, isNull);
      await cubit.close();
    });

    for (final weak in [
      'short',
      'password1234',
      'aaaaaaaaaaaaaaaa',
      '123456789012',
    ]) {
      test('minimum strength is enforced: "$weak"', () async {
        final cubit = build();
        await toPassword(cubit);
        await cubit.submitPassword(password: weak, confirmation: weak);
        expect(cubit.state.step, SetupStep.password);
        expect(cubit.state.error, isNotNull);
        verifyNever(() => repository.prepare(any()));
        await cubit.close();
      });
    }

    test('both entries must match', () async {
      final cubit = build();
      await toPassword(cubit);
      await cubit.submitPassword(
        password: strongPassword,
        confirmation: '${strongPassword}x',
      );
      expect(cubit.state.error, 'The two passwords do not match.');
      verifyNever(() => repository.prepare(any()));
      await cubit.close();
    });

    test(
      'composed and decomposed spellings count as the same password',
      () async {
        final cubit = build();
        await toPassword(cubit);
        await cubit.submitPassword(
          password: 'café-granite-walrus-lantern',
          confirmation: 'café-granite-walrus-lantern',
        );
        expect(cubit.state.step, SetupStep.recoveryKey);
        await cubit.close();
      },
    );

    test('generates the vault and shows the recovery key and TOTP', () async {
      final cubit = build();
      await toRecoveryKey(cubit);

      final state = cubit.state;
      expect(state.step, SetupStep.recoveryKey);
      expect(state.busy, isFalse);
      expect(state.recoveryKey, recoveryKey);
      expect(state.recoveryGroups, hasLength(7));
      expect(state.challengeGroups, [1, 4]);
      expect(state.recoveryAcknowledged, isFalse);
      expect(state.totpSecret, base32EncodeNoPad(material.totpSecret));
      expect(state.totpUri, startsWith('otpauth://totp/Leopard%3APixel%209?'));
      expect(state.totpUri, contains('secret=${state.totpSecret}'));
      verify(() => repository.prepare(strongPassword)).called(1);
      await cubit.close();
    });
  });

  group('recovery key', () {
    test('cannot continue without "I wrote it down"', () async {
      final cubit = build();
      await toRecoveryKey(cubit);
      cubit.continueFromRecoveryKey();
      expect(cubit.state.step, SetupStep.recoveryKey);
      expect(cubit.state.error, isNotNull);

      cubit
        ..acknowledgeRecoveryKey(true)
        ..continueFromRecoveryKey();
      expect(cubit.state.step, SetupStep.recoveryCheck);
      expect(cubit.state.error, isNull);
      await cubit.close();
    });

    test('the two groups must be typed back correctly', () async {
      final cubit = build();
      await toRecoveryKey(cubit);
      cubit
        ..acknowledgeRecoveryKey(true)
        ..continueFromRecoveryKey();

      cubit.submitRecoveryCheck([groups[1], 'ZZZZ']);
      expect(cubit.state.step, SetupStep.recoveryCheck);
      expect(cubit.state.error, isNotNull);

      // Swapped order is wrong too.
      cubit.submitRecoveryCheck([groups[4], groups[1]]);
      expect(cubit.state.step, SetupStep.recoveryCheck);

      cubit.submitRecoveryCheck([groups[1]]);
      expect(cubit.state.step, SetupStep.recoveryCheck);

      // Lower case and stray spaces are forgiven.
      cubit.submitRecoveryCheck([' ${groups[1].toLowerCase()} ', groups[4]]);
      expect(cubit.state.step, SetupStep.totp);
      expect(cubit.state.error, isNull);
      await cubit.close();
    });

    test('the default picker asks for two different groups', () {
      for (var i = 0; i < 200; i++) {
        final picked = pickTwoGroups(7);
        expect(picked, hasLength(2));
        expect(picked[0], lessThan(picked[1]));
        expect(picked, everyElement(inInclusiveRange(0, 6)));
      }
    });
  });

  group('TOTP and commit', () {
    test('a wrong code does not create the vault', () async {
      when(
        () => repository.verifyTotpCode(
          secret: any(named: 'secret'),
          code: any(named: 'code'),
        ),
      ).thenAnswer((_) async => false);
      final cubit = build();
      await toTotp(cubit);
      await cubit.submitTotpCode('000000');

      expect(cubit.state.step, SetupStep.totp);
      expect(cubit.state.busy, isFalse);
      expect(cubit.state.error, contains('not valid'));
      verifyNever(
        () => repository.commit(
          material: any(named: 'material'),
          serverUrl: any(named: 'serverUrl'),
          deviceLabel: any(named: 'deviceLabel'),
          setupToken: any(named: 'setupToken'),
        ),
      );
      await cubit.close();
    });

    test('a valid code calls the setup API with the setup token', () async {
      final cubit = build();
      await toTotp(cubit, token: '  s3tup-t0ken ');
      await cubit.submitTotpCode('123456');

      verify(
        () => repository.verifyTotpCode(
          secret: material.totpSecret,
          code: '123456',
        ),
      ).called(1);
      verify(
        () => repository.commit(
          material: material,
          serverUrl: Uri.parse('https://vault.example.com'),
          deviceLabel: 'Pixel 9',
          setupToken: 's3tup-t0ken',
        ),
      ).called(1);
      // Nothing secret is left in the state.
      expect(cubit.state, const SetupState(step: SetupStep.done));
      await cubit.close();
    });

    test('no setup token is sent when none was entered', () async {
      final cubit = build();
      await toTotp(cubit);
      await cubit.submitTotpCode('123456');
      verify(
        () => repository.commit(
          material: material,
          serverUrl: any(named: 'serverUrl'),
          deviceLabel: 'Pixel 9',
          setupToken: null,
        ),
      ).called(1);
      await cubit.close();
    });

    test('server errors are explained and setup can be retried', () async {
      final cubit = build();
      await toTotp(cubit);
      final answers = <Future<void> Function(Invocation)>[
        (_) async => throw const ForbiddenException(
          statusCode: 403,
          code: 'setup_token_required',
          message: 'x',
        ),
        (_) async => throw const ConflictException(
          statusCode: 409,
          code: 'already_initialised',
          message: 'x',
        ),
        (_) async {},
      ];
      when(
        () => repository.commit(
          material: any(named: 'material'),
          serverUrl: any(named: 'serverUrl'),
          deviceLabel: any(named: 'deviceLabel'),
          setupToken: any(named: 'setupToken'),
        ),
      ).thenAnswer((invocation) => answers.removeAt(0)(invocation));

      await cubit.submitTotpCode('123456');
      expect(cubit.state.step, SetupStep.totp);
      expect(cubit.state.error, 'This server requires a setup token.');

      await cubit.submitTotpCode('123456');
      expect(cubit.state.error, contains('already has a vault'));

      await cubit.submitTotpCode('123456');
      expect(cubit.state.step, SetupStep.done);
      await cubit.close();
    });
  });

  group('back', () {
    test(
      'leaving the recovery key discards and wipes the generated vault',
      () async {
        final cubit = build();
        await toRecoveryKey(cubit);
        cubit.back();

        expect(cubit.state, const SetupState(step: SetupStep.password));
        expect(material.vaultKey, everyElement(0));
        expect(material.recoveryKey, everyElement(0));
        expect(material.deviceKey.seed, everyElement(0));
        await cubit.close();
      },
    );

    test('closing the wizard wipes the generated vault', () async {
      final cubit = build();
      await toRecoveryKey(cubit);
      await cubit.close();
      expect(material.vaultKey, everyElement(0));
      expect(material.totpSecret, everyElement(0));
    });
  });
}
