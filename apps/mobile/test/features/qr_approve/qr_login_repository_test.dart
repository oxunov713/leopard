// QrLoginRepositoryImpl with real crypto: the phone side of crypto-spec §10,
// checked from the browser's point of view.
import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/core/security/biometric_authenticator.dart';
import 'package:leopard_mobile/core/security/key_derivation.dart';
import 'package:leopard_mobile/core/session/vault_session.dart';
import 'package:leopard_mobile/features/qr_approve/data/qr_login_repository_impl.dart';
import 'package:leopard_mobile/features/qr_approve/domain/qr_login_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../support/fakes.dart';

void main() {
  final crypto = newLeopardCrypto();
  final now = DateTime.utc(2026, 11, 11, 10, 0, 5);
  final sid = bytesOf(sidSize, 0x61);
  final vaultKey = bytesOf(keySize, 0x11);
  final deviceSeed = bytesOf(ed25519SeedSize, 0x51);

  late X25519KeyPair browser;
  late String scanned;
  late String code;
  late MockRemoteVault remote;
  late MockBiometricAuthenticator biometrics;
  late VaultSession session;
  late QrLoginRepositoryImpl repository;

  QrDetails details({
    Uint8List? browserPub,
    Uint8List? detailsSid,
    String? verifyCode,
    QrStatus status = QrStatus.pending,
    DateTime? expiresAt,
    Map<String, Object?>? clientInfo,
  }) => QrDetails(
    sid: detailsSid ?? sid,
    status: status,
    browserPub: browserPub ?? browser.publicKey,
    clientInfo:
        clientInfo ??
        const {
          'user_agent': 'Mozilla/5.0 (X11; Linux x86_64)',
          'reported': {'platform': 'Linux', 'browser': 'Firefox'},
        },
    ip: '203.0.113.50',
    createdAt: DateTime.utc(2026, 11, 11, 10),
    expiresAt: expiresAt ?? DateTime.utc(2026, 11, 11, 10, 1),
    verifyCode: verifyCode ?? code,
  );

  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(
      QrApproval(
        phoneEphPub: Uint8List(0),
        nonce: Uint8List(0),
        ciphertext: Uint8List(0),
        signature: Uint8List(0),
      ),
    );
  });

  setUp(() async {
    browser = await crypto.generateX25519KeyPair();
    scanned = QrUri(sid: sid, browserPub: browser.publicKey).toString();
    code = await crypto.verifyCode(sid: sid, browserPub: browser.publicKey);
    remote = MockRemoteVault();
    biometrics = MockBiometricAuthenticator();
    session = await unlockedSession(
      crypto,
      vaultKey: vaultKey,
      deviceSeed: deviceSeed,
    );
    repository = QrLoginRepositoryImpl(
      remote: remote,
      session: session,
      biometrics: biometrics,
      crypto: crypto,
      now: () => now,
    );
    when(() => remote.qrDetails(any())).thenAnswer((_) async => details());
  });

  final throwsRejected = throwsA(isA<QrRejectedFailure>());

  group('load', () {
    test('returns what the user needs to decide', () async {
      final request = await repository.load(scanned);

      expect(request.sid, sid);
      expect(request.browserPub, browser.publicKey);
      expect(request.verifyCode, code);
      expect(request.verifyCode, matches(RegExp(r'^\d{6}$')));
      expect(request.ip, '203.0.113.50');
      expect(request.browser, 'Firefox');
      expect(request.platform, 'Linux');
      expect(request.userAgent, 'Mozilla/5.0 (X11; Linux x86_64)');
      expect(request.expiresAt, DateTime.utc(2026, 11, 11, 10, 1));
      verify(() => remote.qrDetails(sid)).called(1);
    });

    for (final text in [
      'https://example.com/login',
      'leopard://qr?v=2&sid=AAAA&pk=BBBB',
      'leopard://qr?v=1&sid=short&pk=short',
      'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP',
      '',
    ]) {
      test('not a Leopard login code: "$text"', () async {
        await expectLater(repository.load(text), throwsRejected);
        verifyNever(() => remote.qrDetails(any()));
      });
    }

    test('aborts when the server names a different browser key', () async {
      final attacker = await crypto.generateX25519KeyPair();
      when(() => remote.qrDetails(any())).thenAnswer(
        (_) async => details(
          browserPub: attacker.publicKey,
          // A lying server would send the code that fits its own key.
          verifyCode: await crypto.verifyCode(
            sid: sid,
            browserPub: attacker.publicKey,
          ),
        ),
      );
      await expectLater(
        repository.load(scanned),
        throwsA(
          isA<QrRejectedFailure>().having(
            (e) => e.message,
            'message',
            contains('different browser key'),
          ),
        ),
      );
    });

    test('aborts when the server answers for another session', () async {
      when(
        () => remote.qrDetails(any()),
      ).thenAnswer((_) async => details(detailsSid: bytesOf(sidSize, 0x62)));
      await expectLater(repository.load(scanned), throwsRejected);
    });

    test('aborts when the server-supplied code differs', () async {
      when(
        () => remote.qrDetails(any()),
      ).thenAnswer((_) async => details(verifyCode: '000000'));
      await expectLater(repository.load(scanned), throwsRejected);
    });

    test('refuses requests that are expired or no longer pending', () async {
      when(
        () => remote.qrDetails(any()),
      ).thenAnswer((_) async => details(expiresAt: now));
      await expectLater(repository.load(scanned), throwsRejected);

      for (final status in [
        QrStatus.approved,
        QrStatus.rejected,
        QrStatus.expired,
        QrStatus.consumed,
      ]) {
        when(
          () => remote.qrDetails(any()),
        ).thenAnswer((_) async => details(status: status));
        await expectLater(
          repository.load(scanned),
          throwsRejected,
          reason: status.name,
        );
      }
    });

    test('unknown session on the server', () async {
      when(() => remote.qrDetails(any())).thenThrow(
        const NotFoundException(
          statusCode: 404,
          code: 'qr_not_found',
          message: 'x',
        ),
      );
      await expectLater(repository.load(scanned), throwsRejected);
    });

    test('client-supplied text is cleaned and capped', () async {
      when(() => remote.qrDetails(any())).thenAnswer(
        (_) async => details(
          clientInfo: {
            'user_agent': 'A\nB\u0000C${'x' * 500}',
            'reported': {'browser': 42, 'platform': ' Linux\t'},
          },
        ),
      );
      final request = await repository.load(scanned);
      expect(request.browser, '');
      expect(request.platform, 'Linux');
      expect(request.userAgent, startsWith('A B C'));
      expect(request.userAgent.length, lessThanOrEqualTo(201));
    });
  });

  group('confirmPresence', () {
    test('is true only for a successful biometric', () async {
      for (final outcome in BiometricOutcome.values) {
        when(
          () => biometrics.authenticate(reason: any(named: 'reason')),
        ).thenAnswer((_) async => outcome);
        expect(
          await repository.confirmPresence(),
          outcome == BiometricOutcome.success,
          reason: outcome.name,
        );
      }
    });
  });

  group('approve', () {
    test('the browser can open the vault key and the server can verify '
        'the signature', () async {
      QrApproval? sent;
      when(
        () => remote.approveQr(
          sid: any(named: 'sid'),
          approval: any(named: 'approval'),
        ),
      ).thenAnswer((invocation) async {
        sent = invocation.namedArguments[#approval] as QrApproval;
        return const QrApproveResult(webSessionId: deviceIdA);
      });
      final request = await repository.load(scanned);

      await repository.approve(request);

      final approval = sent!;
      // Browser side (crypto-spec §10.1 step 9).
      final opened = await crypto.qrOpenVaultKey(
        browserPrivateKey: browser.privateKey,
        phoneEphPub: approval.phoneEphPub,
        sid: sid,
        nonce: approval.nonce,
        ciphertext: approval.ciphertext,
      );
      expect(opened, vaultKey);
      // Server side (step 7): signed by this phone's registered key.
      final device = await crypto.ed25519KeyPairFromSeed(deviceSeed);
      expect(
        await crypto.ed25519Verify(
          publicKey: device.publicKey,
          message: LeopardCrypto.qrApproveMessage(
            sid: sid,
            browserPub: browser.publicKey,
            phoneEphPub: approval.phoneEphPub,
            nonce: approval.nonce,
            ciphertext: approval.ciphertext,
          ),
          signature: approval.signature,
        ),
        isTrue,
      );
      // Another browser cannot open it.
      final other = await crypto.generateX25519KeyPair();
      await expectLater(
        crypto.qrOpenVaultKey(
          browserPrivateKey: other.privateKey,
          phoneEphPub: approval.phoneEphPub,
          sid: sid,
          nonce: approval.nonce,
          ciphertext: approval.ciphertext,
        ),
        throwsA(isA<DecryptException>()),
      );
    });

    test('fresh ephemeral key and nonce for every approval', () async {
      final approvals = <QrApproval>[];
      when(
        () => remote.approveQr(
          sid: any(named: 'sid'),
          approval: any(named: 'approval'),
        ),
      ).thenAnswer((invocation) async {
        approvals.add(invocation.namedArguments[#approval] as QrApproval);
        return const QrApproveResult(webSessionId: deviceIdA);
      });
      final request = await repository.load(scanned);
      await repository.approve(request);
      await repository.approve(request);
      expect(approvals[0].phoneEphPub, isNot(approvals[1].phoneEphPub));
      expect(approvals[0].nonce, isNot(approvals[1].nonce));
    });

    test('nothing is sent while the vault is locked', () async {
      final request = await repository.load(scanned);
      session.close();
      await expectLater(repository.approve(request), throwsA(anything));
      verifyNever(
        () => remote.approveQr(
          sid: any(named: 'sid'),
          approval: any(named: 'approval'),
        ),
      );
    });
  });

  test('reject tells the server', () async {
    when(() => remote.rejectQr(any())).thenAnswer((_) async {});
    final request = await repository.load(scanned);
    await repository.reject(request);
    verify(() => remote.rejectQr(sid)).called(1);
  });
}
