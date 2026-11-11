/// String key/value storage whose values are encrypted at rest.
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> deleteAll();
}
