import '../core/network/remote_vault.dart';
import '../core/security/local_auth_device_authenticator.dart';
import '../core/security/device_authenticator.dart';
import '../core/security/key_derivation.dart';
import '../core/security/platform_secret_clipboard.dart';
import '../core/security/secret_clipboard.dart';
import '../core/session/vault_session.dart';
import '../core/storage/device_store.dart';
import '../core/storage/flutter_secure_key_value_store.dart';
import '../features/qr_approve/data/qr_login_repository_impl.dart';
import '../features/qr_approve/domain/qr_login_repository.dart';
import '../features/sessions/data/sessions_repository_impl.dart';
import '../features/sessions/domain/sessions_repository.dart';
import '../features/setup/data/setup_repository_impl.dart';
import '../features/setup/domain/setup_repository.dart';
import '../features/unlock/data/unlock_repository_impl.dart';
import '../features/unlock/domain/unlock_repository.dart';
import '../features/vault/data/vault_repository_impl.dart';
import '../features/vault/domain/vault_repository.dart';

/// Everything the widget tree needs, wired once at startup.
///
/// Tests build one from fakes with the default constructor; the app uses
/// [AppDependencies.production].
final class AppDependencies {
  AppDependencies({
    required this.deviceStore,
    required this.session,
    required this.remote,
    required this.clipboard,
    required this.deviceAuthenticator,
    required this.setupRepository,
    required this.unlockRepository,
    required this.vaultRepository,
    required this.qrLoginRepository,
    required this.sessionsRepository,
  });

  factory AppDependencies.production() {
    final crypto = newLeopardCrypto();
    final session = VaultSession();
    final store = SecureDeviceStore(FlutterSecureKeyValueStore());
    final remote = ApiRemoteVault(session: session, crypto: crypto);
    final deviceAuth = LocalAuthDeviceAuthenticator();
    const keyDerivation = IsolateKeyDerivation();
    return AppDependencies(
      deviceStore: store,
      session: session,
      remote: remote,
      clipboard: PlatformSecretClipboard(),
      deviceAuthenticator: deviceAuth,
      setupRepository: SetupRepositoryImpl(
        store: store,
        session: session,
        remote: remote,
        keyDerivation: keyDerivation,
        crypto: crypto,
      ),
      unlockRepository: UnlockRepositoryImpl(
        store: store,
        session: session,
        remote: remote,
        deviceAuth: deviceAuth,
        keyDerivation: keyDerivation,
        crypto: crypto,
      ),
      vaultRepository: VaultRepositoryImpl(
        remote: remote,
        session: session,
        crypto: crypto,
      ),
      qrLoginRepository: QrLoginRepositoryImpl(
        remote: remote,
        session: session,
        deviceAuth: deviceAuth,
        store: store,
        keyDerivation: keyDerivation,
        crypto: crypto,
      ),
      sessionsRepository: SessionsRepositoryImpl(remote),
    );
  }

  final DeviceStore deviceStore;
  final VaultSession session;
  final RemoteVault remote;
  final SecretClipboard clipboard;
  final DeviceAuthenticator deviceAuthenticator;
  final SetupRepository setupRepository;
  final UnlockRepository unlockRepository;
  final VaultRepository vaultRepository;
  final QrLoginRepository qrLoginRepository;
  final SessionsRepository sessionsRepository;
}
