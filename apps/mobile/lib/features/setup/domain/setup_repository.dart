import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

/// Validates the address of a Leopard server typed by the user.
///
/// Only `https` origins (with an optional path prefix) are accepted.
/// Returns `null` when the text is not acceptable.
Uri? parseServerUrl(String input) {
  final text = input.trim();
  if (text.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

/// Rules for a new master password. The master password is the last line
/// of defence if the server is ever compromised (crypto-spec §1).
abstract final class MasterPasswordPolicy {
  static const int minLength = 12;

  /// Minimum estimate from `estimatePasswordStrength`, in bits.
  static const double minBits = 60;

  /// `null` when [password] is acceptable, otherwise what is wrong with it.
  static String? problemWith(String password) {
    if (password.length < minLength) {
      return 'Use at least $minLength characters.';
    }
    final strength = estimatePasswordStrength(password);
    if (strength.patterns.contains(PasswordPattern.common)) {
      return 'This is a commonly used password.';
    }
    if (strength.bits < minBits) {
      return 'Too easy to guess. Make it longer or less predictable.';
    }
    return null;
  }
}

abstract interface class SetupRepository {
  /// Checks that a Leopard server answers at [serverUrl].
  Future<void> checkServer(Uri serverUrl);

  /// Generates every secret of a new vault. Slow (Argon2id); runs off the
  /// UI isolate.
  Future<VaultSetupMaterial> prepare(String masterPassword);

  /// Whether [code] is a valid TOTP code for [secret] right now (± 30 s).
  Future<bool> verifyTotpCode({
    required Uint8List secret,
    required String code,
  });

  /// Creates the vault on the server, stores the keys on this phone and
  /// unlocks. Consumes (wipes) [material].
  Future<void> commit({
    required VaultSetupMaterial material,
    required Uri serverUrl,
    required String deviceLabel,
    String? setupToken,
  });
}
