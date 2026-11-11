import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../error/failures.dart';
import 'secure_key_value_store.dart';

/// [SecureKeyValueStore] on `flutter_secure_storage`.
///
/// On Android the values are AES-GCM encrypted with a key that is itself
/// wrapped by a key held in the Android Keystore, so the files on disk are
/// useless without this device's Keystore.
final class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore({FlutterSecureStorage? storage})
    : _storage =
          storage ?? const FlutterSecureStorage(aOptions: androidOptions);

  /// `resetOnError: false`: if the Keystore key is lost the app reports an
  /// error instead of silently wiping the vault key and device key.
  static const AndroidOptions androidOptions = AndroidOptions(
    resetOnError: false,
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _guard(() => _storage.read(key: key));

  @override
  Future<void> write(String key, String value) =>
      _guard(() => _storage.write(key: key, value: value));

  @override
  Future<void> deleteAll() => _guard(_storage.deleteAll);

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PlatformException {
      throw const StorageFailure();
    }
  }
}
