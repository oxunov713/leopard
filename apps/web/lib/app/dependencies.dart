import 'package:leopard_core/leopard_core.dart';

import '../core/config/app_config.dart';
import '../core/network/client_info.dart';
import '../core/network/leopard_api.dart';
import '../core/security/flutter_secret_clipboard.dart';
import '../core/security/key_derivation.dart';
import '../core/security/password_handoff.dart';
import '../core/security/secret_clipboard.dart';
import '../core/session/vault_session.dart';
import '../features/emergency_login/data/emergency_login_repository_impl.dart';
import '../features/emergency_login/domain/emergency_login_repository.dart';
import '../features/qr_login/data/qr_login_repository_impl.dart';
import '../features/qr_login/domain/qr_login_repository.dart';
import '../features/vault/data/vault_repository_impl.dart';
import '../features/vault/domain/vault_repository.dart';

/// Everything the widget tree needs, wired once at startup.
///
/// Tests build one from fakes with the default constructor; the app uses
/// [AppDependencies.production].
final class AppDependencies {
  AppDependencies({
    required this.session,
    required this.api,
    required this.clipboard,
    required this.passwordHandoff,
    required this.qrLoginRepository,
    required this.emergencyLoginRepository,
    required this.vaultRepository,
    this.now = DateTime.now,
  });

  /// [config] must be valid (see [AppConfig.isValid]).
  factory AppDependencies.production(AppConfig config) {
    // The default `Cryptography` instance: Web Crypto in a browser for
    // AES-GCM, HKDF, SHA-256 and (where the browser has them) X25519.
    final crypto = LeopardCrypto();
    final session = VaultSession();
    final api = HttpLeopardApi(
      baseUrl: config.apiUrl!,
      allowInsecureHttp: config.allowInsecureHttp,
    );
    return AppDependencies(
      session: session,
      api: api,
      clipboard: FlutterSecretClipboard(),
      passwordHandoff: PasswordHandoff(),
      qrLoginRepository: QrLoginRepositoryImpl(
        api: api,
        session: session,
        crypto: crypto,
        clientInfo: describeThisBrowser,
      ),
      emergencyLoginRepository: EmergencyLoginRepositoryImpl(
        api: api,
        session: session,
        crypto: crypto,
        keyDerivation: InlineKeyDerivation(crypto),
        clientInfo: describeThisBrowser,
      ),
      vaultRepository: VaultRepositoryImpl(
        api: api,
        session: session,
        crypto: crypto,
      ),
    );
  }

  final VaultSession session;
  final LeopardApi api;
  final SecretClipboard clipboard;
  final PasswordHandoff passwordHandoff;
  final QrLoginRepository qrLoginRepository;
  final EmergencyLoginRepository emergencyLoginRepository;
  final VaultRepository vaultRepository;

  /// The clock behind every session deadline. Replaced in tests.
  final DateTime Function() now;
}
