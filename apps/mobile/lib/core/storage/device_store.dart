import 'dart:convert';
import 'dart:typed_data';

import 'package:leopard_core/leopard_core.dart';

import '../error/failures.dart';
import 'secure_key_value_store.dart';

/// What identifies this phone to its server. Not secret.
final class DeviceRegistration {
  const DeviceRegistration({
    required this.serverUrl,
    required this.deviceId,
    required this.deviceLabel,
  });

  final Uri serverUrl;
  final String deviceId;
  final String deviceLabel;
}

/// The two long-term secrets of the phone. Wipe with [destroy] after use.
final class DeviceSecrets {
  DeviceSecrets({required this.vaultKey, required this.deviceSeed});

  final Uint8List vaultKey;
  final Uint8List deviceSeed;

  void destroy() => wipeAll([vaultKey, deviceSeed]);
}

/// What the master-password fallback needs to recover the vault key offline:
/// the same wrapped key, salt and parameters the server stores.
final class MasterUnlockMaterial {
  const MasterUnlockMaterial({
    required this.wrappedVaultKey,
    required this.salt,
    required this.kdfParams,
  });

  final Uint8List wrappedVaultKey;
  final Uint8List salt;
  final KdfParams kdfParams;
}

/// Persistent state of the phone.
abstract interface class DeviceStore {
  /// `null` until setup has completed on this phone.
  Future<DeviceRegistration?> readRegistration();

  Future<DeviceSecrets> readSecrets();

  Future<MasterUnlockMaterial> readMasterMaterial();

  /// Stores the secrets. Called before the server is asked to create the
  /// vault, so a storage problem is found while nothing is committed yet.
  Future<void> saveSecrets({
    required DeviceSecrets secrets,
    required MasterUnlockMaterial masterMaterial,
  });

  /// Stores the registration; from then on [readRegistration] is non-null.
  Future<void> saveRegistration(DeviceRegistration registration);

  /// Removes everything. The vault on the server is not touched.
  Future<void> erase();
}

/// [DeviceStore] on a [SecureKeyValueStore].
final class SecureDeviceStore implements DeviceStore {
  SecureDeviceStore(this._store);

  static const String _kServerUrl = 'leopard.v1.server_url';
  static const String _kDeviceId = 'leopard.v1.device_id';
  static const String _kDeviceLabel = 'leopard.v1.device_label';
  static const String _kVaultKey = 'leopard.v1.vault_key';
  static const String _kDeviceSeed = 'leopard.v1.device_seed';
  static const String _kWrappedVk = 'leopard.v1.wrapped_vk_master';
  static const String _kSalt = 'leopard.v1.kdf_salt';
  static const String _kKdfParams = 'leopard.v1.kdf_params';

  final SecureKeyValueStore _store;

  @override
  Future<DeviceRegistration?> readRegistration() async {
    final deviceId = await _store.read(_kDeviceId);
    final serverUrl = await _store.read(_kServerUrl);
    if (deviceId == null || serverUrl == null) {
      return null;
    }
    final uri = Uri.tryParse(serverUrl);
    if (uri == null || uri.scheme != 'https' || !isCanonicalUuid(deviceId)) {
      throw const StorageFailure('The saved device registration is damaged.');
    }
    return DeviceRegistration(
      serverUrl: uri,
      deviceId: deviceId,
      deviceLabel: await _store.read(_kDeviceLabel) ?? '',
    );
  }

  @override
  Future<DeviceSecrets> readSecrets() async {
    final vaultKey = await _bytes(_kVaultKey, keySize);
    final deviceSeed = await _bytes(_kDeviceSeed, ed25519SeedSize);
    return DeviceSecrets(vaultKey: vaultKey, deviceSeed: deviceSeed);
  }

  @override
  Future<MasterUnlockMaterial> readMasterMaterial() async {
    final rawParams = await _store.read(_kKdfParams);
    if (rawParams == null) {
      throw const StorageFailure('The saved key material is missing.');
    }
    final KdfParams params;
    try {
      final json = jsonDecode(rawParams);
      if (json is! Map<String, Object?>) {
        throw const FormatException();
      }
      params = KdfParams.fromJson(json)..validate();
    } on Exception {
      throw const StorageFailure('The saved key material is damaged.');
    }
    return MasterUnlockMaterial(
      wrappedVaultKey: await _bytes(_kWrappedVk, wrappedVkSize),
      salt: await _bytes(_kSalt, params.saltLength),
      kdfParams: params,
    );
  }

  @override
  Future<void> saveSecrets({
    required DeviceSecrets secrets,
    required MasterUnlockMaterial masterMaterial,
  }) async {
    await _store.write(_kVaultKey, base64UrlEncodeNoPad(secrets.vaultKey));
    await _store.write(_kDeviceSeed, base64UrlEncodeNoPad(secrets.deviceSeed));
    await _store.write(
      _kWrappedVk,
      base64UrlEncodeNoPad(masterMaterial.wrappedVaultKey),
    );
    await _store.write(_kSalt, base64UrlEncodeNoPad(masterMaterial.salt));
    await _store.write(
      _kKdfParams,
      jsonEncode(masterMaterial.kdfParams.toJson()),
    );
  }

  @override
  Future<void> saveRegistration(DeviceRegistration registration) async {
    if (registration.serverUrl.scheme != 'https') {
      throw const ValidationFailure('The server address must use https.');
    }
    await _store.write(_kServerUrl, registration.serverUrl.toString());
    await _store.write(_kDeviceLabel, registration.deviceLabel);
    // Written last: its presence is what marks setup as complete.
    await _store.write(_kDeviceId, registration.deviceId);
  }

  @override
  Future<void> erase() => _store.deleteAll();

  Future<Uint8List> _bytes(String key, int size) async {
    final text = await _store.read(key);
    if (text == null) {
      throw const StorageFailure('The saved key material is missing.');
    }
    try {
      final bytes = base64UrlDecodeNoPad(text);
      if (bytes.length != size) {
        wipe(bytes);
        throw const InvalidSizeException('unexpected size');
      }
      return bytes;
    } on LeopardCryptoException {
      throw const StorageFailure('The saved key material is damaged.');
    }
  }
}
