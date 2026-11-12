// QrLoginRepositoryImpl with the real crypto of leopard_core. The phone's
// half of the protocol (crypto-spec §10.1 step 6) is done by the test.
import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_web/core/error/failures.dart';
import 'package:leopard_web/core/session/vault_session.dart';
import 'package:leopard_web/features/qr_login/data/qr_login_repository_impl.dart';
import 'package:leopard_web/features/qr_login/domain/qr_login_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  final crypto = LeopardCrypto();
  final sid = bytesOf(sidSize, 0x05);
  final vaultKey = bytesOf(keySize, 0x11);
  final deviceSeed = bytesOf(ed25519SeedSize, 0x51);
  final pollToken = tokenOf(0x61);

  late MockLeopardApi api;
  late VaultSession session;
  late QrLoginRepositoryImpl repository;
  late Uint8List browserPub;
  Map<String, Object?>? sentClientInfo;

  setUpAll(() => registerFallbackValue(Uint8List(0)));

  /// A server that answers `POST /v1/qr` honestly for whatever key it gets.
  void honestServer() {
    when(
      () => api.createQrSession(
        browserPub: any(named: 'browserPub'),
        clientInfo: any(named: 'clientInfo'),
      ),
    ).thenAnswer((invocation) async {
      browserPub = invocation.namedArguments[#browserPub] as Uint8List;
      sentClientInfo =
          invocation.namedArguments[#clientInfo] as Map<String, Object?>?;
      return QrSession(
        sid: sid,
        pollToken: pollToken,
        expiresAt: t0.add(const Duration(seconds: 60)),
        verifyCode: await crypto.verifyCode(sid: sid, browserPub: browserPub),
        qrUri: QrUri(sid: sid, browserPub: browserPub).toString(),
      );
    });
  }

  void pollAnswers(QrPollResult result) {
    when(
      () => api.pollQrSession(sid: sid, pollToken: pollToken),
    ).thenAnswer((_) async => result);
  }

  /// What the phone sends after scanning [attempt]'s QR code.
  Future<QrPollApproved> approvalFor(
    QrLoginAttempt attempt, {
    Uint8List? forSid,
  }) async {
    final scanned = QrUri.parse(attempt.qrText);
    final approval = await crypto.approveQrLogin(
      vaultKey: vaultKey,
      deviceSeed: deviceSeed,
      sid: forSid ?? scanned.sid,
      browserPub: scanned.browserPub,
    );
    return QrPollApproved(
      session: webGrant(),
      phoneEphPub: approval.phoneEphPub,
      nonce: approval.nonce,
      ciphertext: approval.ciphertext,
    );
  }

  setUp(() {
    api = MockLeopardApi();
    session = VaultSession();
    sentClientInfo = null;
    repository = QrLoginRepositoryImpl(
      api: api,
      session: session,
      crypto: crypto,
      clientInfo: () => {'browser': 'Leopard web', 'platform': 'Linux'},
    );
    when(() => api.logout()).thenAnswer((_) async {});
    honestServer();
  });

  group('begin', () {
    test('sends only the public key and builds the QR text locally', () async {
      final attempt = await repository.begin();

      expect(attempt.keyPair.publicKey, browserPub);
      expect(
        await crypto.x25519PublicKey(attempt.keyPair.privateKey),
        browserPub,
      );
      final parsed = QrUri.parse(attempt.qrText);
      expect(parsed.sid, sid);
      expect(parsed.browserPub, browserPub);
      expect(
        attempt.qrText,
        isNot(contains(pollToken)),
        reason: 'the poll token must not be in the QR code',
      );
      expect(attempt.verifyCode, matches(RegExp(r'^\d{6}$')));
      expect(
        attempt.verifyCode,
        await crypto.verifyCode(sid: sid, browserPub: browserPub),
      );
      expect(sentClientInfo, {'browser': 'Leopard web', 'platform': 'Linux'});
    });

    test('every attempt has a fresh key pair', () async {
      final first = await repository.begin();
      final second = await repository.begin();
      expect(first.keyPair.publicKey, isNot(second.keyPair.publicKey));
    });

    test('a server that reports another verification code is refused', () {
      when(
        () => api.createQrSession(
          browserPub: any(named: 'browserPub'),
          clientInfo: any(named: 'clientInfo'),
        ),
      ).thenAnswer((invocation) async {
        final pub = invocation.namedArguments[#browserPub] as Uint8List;
        return QrSession(
          sid: sid,
          pollToken: pollToken,
          expiresAt: t0,
          verifyCode: '000000',
          qrUri: QrUri(sid: sid, browserPub: pub).toString(),
        );
      });
      expect(repository.begin(), throwsA(isA<ServerMismatchFailure>()));
    });

    test('a server that swaps the key in the QR text is refused', () {
      when(
        () => api.createQrSession(
          browserPub: any(named: 'browserPub'),
          clientInfo: any(named: 'clientInfo'),
        ),
      ).thenAnswer((invocation) async {
        final pub = invocation.namedArguments[#browserPub] as Uint8List;
        final attacker = bytesOf(x25519KeySize, 0x77);
        return QrSession(
          sid: sid,
          pollToken: pollToken,
          expiresAt: t0,
          verifyCode: await crypto.verifyCode(sid: sid, browserPub: pub),
          qrUri: QrUri(sid: sid, browserPub: attacker).toString(),
        );
      });
      expect(repository.begin(), throwsA(isA<ServerMismatchFailure>()));
    });
  });

  group('poll', () {
    test('pending keeps the attempt alive', () async {
      final attempt = await repository.begin();
      pollAnswers(const QrPollWaiting(status: QrStatus.pending));

      expect(await repository.poll(attempt), QrPollOutcome.pending);
      expect(attempt.isDestroyed, isFalse);
      expect(session.isUnlocked, isFalse);
    });

    test(
      'approved: the vault key is decrypted and the private key wiped',
      () async {
        final attempt = await repository.begin();
        pollAnswers(await approvalFor(attempt));

        expect(await repository.poll(attempt), QrPollOutcome.signedIn);

        final vault = session.require;
        expect(vault.vaultKey, vaultKey);
        expect(vault.itemKey, await crypto.deriveItemKey(vaultKey));
        expect(vault.sessionId, sessionIdA);
        expect(vault.method, LoginMethod.qr);
        expect(vault.idleTimeout, const Duration(seconds: 300));
        expect(attempt.isDestroyed, isTrue);
        expect(attempt.keyPair.privateKey, everyElement(0));
        verifyNever(() => api.logout());
      },
    );

    for (final (status, outcome) in [
      (QrStatus.rejected, QrPollOutcome.rejected),
      (QrStatus.expired, QrPollOutcome.expired),
      (QrStatus.consumed, QrPollOutcome.consumed),
    ]) {
      test('${status.wireName} ends the attempt', () async {
        final attempt = await repository.begin();
        pollAnswers(QrPollWaiting(status: status));

        expect(await repository.poll(attempt), outcome);
        expect(attempt.keyPair.privateKey, everyElement(0));
        expect(session.isUnlocked, isFalse);
      });
    }

    test('404 qr_not_found counts as expired', () async {
      final attempt = await repository.begin();
      when(() => api.pollQrSession(sid: sid, pollToken: pollToken)).thenThrow(
        const NotFoundException(
          statusCode: 404,
          code: 'qr_not_found',
          message: 'x',
        ),
      );
      expect(await repository.poll(attempt), QrPollOutcome.expired);
      expect(attempt.isDestroyed, isTrue);
    });

    test('a payload made for another session is refused and the '
        'session revoked', () async {
      final attempt = await repository.begin();
      pollAnswers(await approvalFor(attempt, forSid: bytesOf(sidSize, 0x99)));

      await expectLater(
        repository.poll(attempt),
        throwsA(isA<ServerMismatchFailure>()),
      );
      expect(session.isUnlocked, isFalse);
      expect(attempt.keyPair.privateKey, everyElement(0));
      verify(() => api.logout()).called(1);
    });

    test('a payload made for another browser key is refused', () async {
      final attempt = await repository.begin();
      final other = await repository.begin();
      pollAnswers(await approvalFor(other));

      await expectLater(
        repository.poll(attempt),
        throwsA(isA<ServerMismatchFailure>()),
      );
      expect(session.isUnlocked, isFalse);
    });

    test('a network error leaves the attempt usable', () async {
      final attempt = await repository.begin();
      when(() => api.pollQrSession(sid: sid, pollToken: pollToken)).thenThrow(
        const ServerException(statusCode: 502, code: 'x', message: 'x'),
      );
      await expectLater(
        repository.poll(attempt),
        throwsA(isA<ServerException>()),
      );
      expect(attempt.isDestroyed, isFalse);

      pollAnswers(await approvalFor(attempt));
      expect(await repository.poll(attempt), QrPollOutcome.signedIn);
    });

    test('an abandoned attempt is never polled', () async {
      final attempt = await repository.begin();
      repository.abandon(attempt);
      expect(attempt.keyPair.privateKey, everyElement(0));
      expect(await repository.poll(attempt), QrPollOutcome.expired);
      verifyNever(
        () => api.pollQrSession(
          sid: any(named: 'sid'),
          pollToken: any(named: 'pollToken'),
        ),
      );
    });
  });
}
