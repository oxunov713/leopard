import 'dart:io';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/core/error/failures.dart';
import 'package:leopard_mobile/features/restore/domain/restore_repository.dart';
import 'package:leopard_mobile/features/restore/presentation/restore_cubit.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

const password = 'granite-walrus-47-lantern-oboe';

void main() {
  late MockRestoreRepository repository;
  late Uint8List recoveryKey;
  late String display;

  /// Copies of the recovery key bytes the repository was given, taken at
  /// call time (the cubit wipes its buffer afterwards).
  late List<Uint8List> receivedKeys;

  /// The buffers themselves, to check that they were wiped.
  late List<Uint8List> receivedBuffers;

  setUpAll(() {
    registerFallbackValue(Uri.parse('https://fallback.example'));
    registerFallbackValue(Uint8List(0));
  });

  setUp(() {
    repository = MockRestoreRepository();
    recoveryKey = bytesOf(recoveryKeySize, 10);
    display = formatRecoveryKey(recoveryKey);
    receivedKeys = [];
    receivedBuffers = [];
    when(
      () => repository.restore(
        serverUrl: any(named: 'serverUrl'),
        deviceLabel: any(named: 'deviceLabel'),
        recoveryKey: any(named: 'recoveryKey'),
        masterPassword: any(named: 'masterPassword'),
      ),
    ).thenAnswer((invocation) async {
      final key = invocation.namedArguments[#recoveryKey] as Uint8List;
      receivedBuffers.add(key);
      receivedKeys.add(Uint8List.fromList(key));
    });
    when(() => repository.openRestoredVault()).thenAnswer((_) async {});
  });

  RestoreCubit build() => RestoreCubit(repository);

  Future<void> submit(
    RestoreCubit cubit, {
    String serverUrl = 'https://vault.example.com',
    String deviceLabel = 'New phone',
    String? key,
    String masterPassword = password,
    String? confirmation,
  }) => cubit.submit(
    serverUrl: serverUrl,
    deviceLabel: deviceLabel,
    recoveryKey: key ?? display,
    masterPassword: masterPassword,
    confirmation: confirmation ?? masterPassword,
  );

  void neverRestored() => verifyNever(
    () => repository.restore(
      serverUrl: any(named: 'serverUrl'),
      deviceLabel: any(named: 'deviceLabel'),
      recoveryKey: any(named: 'recoveryKey'),
      masterPassword: any(named: 'masterPassword'),
    ),
  );

  group('recovery key format', () {
    test('accepts groups, spaces, no dashes and lower case', () async {
      final plain = display.replaceAll('-', '');
      for (final typed in [
        display,
        display.toLowerCase(),
        display.replaceAll('-', ' '),
        plain,
        ' ${plain.substring(0, 13)}\n${plain.substring(13).toLowerCase()} ',
      ]) {
        final cubit = build();
        await submit(cubit, key: typed);
        expect(cubit.state.step, RestoreStep.done, reason: typed);
        await cubit.close();
      }
      expect(receivedKeys, hasLength(5));
      for (final key in receivedKeys) {
        expect(key, recoveryKey);
      }
      for (final buffer in receivedBuffers) {
        expect(buffer, everyElement(0), reason: 'wiped after the call');
      }
    });

    for (final bad in [
      'EAQS-EIZE-EUTC',
      '${'A' * 26}A',
      // 0, 1, 8 and 9 are not in the Base32 alphabet.
      'EAQS-EIZE-EUTC-OKBJ-FIVS-YLJO-F0',
      'EAQS-EIZE-EUTC-OKBJ-FIVS-YLJO-F1',
      // The two surplus bits must be zero.
      'EAQS-EIZE-EUTC-OKBJ-FIVS-YLJO-F7',
      'EAQS_EIZE_EUTC_OKBJ_FIVS_YLJO_F4',
    ]) {
      test('rejects "$bad" before any network call', () async {
        final cubit = build();
        await submit(cubit, key: bad);
        expect(cubit.state.step, RestoreStep.form);
        expect(cubit.state.busy, isFalse);
        expect(cubit.state.error, malformedRecoveryKeyMessage);
        neverRestored();
        await cubit.close();
      });
    }

    test('an empty key asks for it', () async {
      final cubit = build();
      await submit(cubit, key: '   ');
      expect(cubit.state.error, contains('recovery key'));
      neverRestored();
      await cubit.close();
    });
  });

  group('other fields', () {
    test('needs an https server address', () async {
      for (final bad in ['', 'http://vault.example.com', 'vault.example']) {
        final cubit = build();
        await submit(cubit, serverUrl: bad);
        expect(cubit.state.error, contains('https://'));
        await cubit.close();
      }
      neverRestored();
    });

    test('needs a device name', () async {
      final cubit = build();
      await submit(cubit, deviceLabel: '  ');
      expect(cubit.state.error, contains('name'));
      neverRestored();
      await cubit.close();
    });

    test('needs the master password, typed twice the same', () async {
      final cubit = build();
      await submit(cubit, masterPassword: '');
      expect(cubit.state.error, contains('master password'));
      await submit(cubit, confirmation: 'something else');
      expect(cubit.state.error, 'The two passwords do not match.');
      neverRestored();
      await cubit.close();
    });

    test('the password is compared after NFC', () async {
      final cubit = build();
      await submit(
        cubit,
        masterPassword: 'café-walrus-lantern',
        confirmation: 'café-walrus-lantern',
      );
      expect(cubit.state.step, RestoreStep.done);
      await cubit.close();
    });
  });

  group('restore', () {
    blocTest<RestoreCubit, RestoreState>(
      'restores, then waits for the user before opening the vault',
      build: build,
      act: submit,
      expect: () => const [
        RestoreState(busy: true),
        RestoreState(step: RestoreStep.done),
      ],
      verify: (_) {
        verify(
          () => repository.restore(
            serverUrl: Uri.parse('https://vault.example.com'),
            deviceLabel: 'New phone',
            recoveryKey: any(named: 'recoveryKey'),
            masterPassword: password,
          ),
        ).called(1);
        verifyNever(() => repository.openRestoredVault());
      },
    );

    blocTest<RestoreCubit, RestoreState>(
      'open vault after the notice',
      build: build,
      seed: () => const RestoreState(step: RestoreStep.done),
      act: (cubit) => cubit.openVault(),
      expect: () => const [RestoreState(step: RestoreStep.done, busy: true)],
      verify: (_) => verify(() => repository.openRestoredVault()).called(1),
    );

    test('open vault does nothing before a restore', () async {
      final cubit = build();
      await cubit.openVault();
      verifyNever(() => repository.openRestoredVault());
      await cubit.close();
    });

    test('a second submit while busy is ignored', () async {
      final cubit = build();
      await Future.wait([submit(cubit), submit(cubit)]);
      expect(receivedKeys, hasLength(1));
      await cubit.close();
    });

    Future<String?> errorFor(Object error) async {
      when(
        () => repository.restore(
          serverUrl: any(named: 'serverUrl'),
          deviceLabel: any(named: 'deviceLabel'),
          recoveryKey: any(named: 'recoveryKey'),
          masterPassword: any(named: 'masterPassword'),
        ),
      ).thenThrow(error);
      final cubit = build();
      await submit(cubit);
      expect(cubit.state.step, RestoreStep.form);
      expect(cubit.state.busy, isFalse);
      await cubit.close();
      return cubit.state.error;
    }

    test('wrong key', () async {
      expect(
        await errorFor(
          const UnauthorizedException(
            statusCode: 401,
            code: 'invalid_credentials',
            message: 'invalid credentials',
          ),
        ),
        allOf(contains('did not accept this recovery key'), contains('5')),
      );
    });

    test('rate limited, with and without Retry-After', () async {
      expect(
        await errorFor(
          const RateLimitedException(
            statusCode: 429,
            code: 'rate_limited',
            message: 'x',
            retryAfter: Duration(seconds: 1790),
          ),
        ),
        contains('Wait 30 minutes'),
      );
      expect(
        await errorFor(
          const RateLimitedException(
            statusCode: 429,
            code: 'rate_limited',
            message: 'x',
            retryAfter: Duration(seconds: 20),
          ),
        ),
        contains('Wait a minute'),
      );
      expect(
        await errorFor(
          const RateLimitedException(
            statusCode: 429,
            code: 'rate_limited',
            message: 'x',
          ),
        ),
        contains('Too many recovery attempts'),
      );
    });

    test('network errors', () async {
      expect(
        await errorFor(const SocketException('no route')),
        'Cannot reach the server. Check the connection.',
      );
    });

    test('not a Leopard server', () async {
      expect(
        await errorFor(const ValidationFailure('No Leopard server here.')),
        'No Leopard server here.',
      );
    });

    test('post-register failure: others out, retry is safe', () async {
      final message = await errorFor(
        const RestoreIncompleteFailure(StorageFailure()),
      );
      expect(message, contains('signed out every other phone'));
      expect(message, contains('again with the same recovery key is safe'));
    });

    test('a vault key that does not open', () async {
      expect(
        await errorFor(const DecryptException()),
        contains('does not open'),
      );
    });

    test('the key buffer is wiped when the repository fails', () async {
      when(
        () => repository.restore(
          serverUrl: any(named: 'serverUrl'),
          deviceLabel: any(named: 'deviceLabel'),
          recoveryKey: any(named: 'recoveryKey'),
          masterPassword: any(named: 'masterPassword'),
        ),
      ).thenAnswer((invocation) async {
        receivedBuffers.add(
          invocation.namedArguments[#recoveryKey] as Uint8List,
        );
        throw const StorageFailure();
      });
      final cubit = build();
      await submit(cubit);
      expect(cubit.state.error, const StorageFailure().message);
      expect(receivedBuffers.single, everyElement(0));
      await cubit.close();
    });
  });
}
