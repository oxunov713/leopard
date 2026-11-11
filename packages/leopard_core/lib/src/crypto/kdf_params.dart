import 'constants.dart';
import 'errors.dart';

/// Argon2id parameters (crypto-spec §5). They travel with the vault so they
/// can be raised later.
final class KdfParams {
  const KdfParams({
    required this.algorithm,
    required this.version,
    required this.memoryKib,
    required this.iterations,
    required this.parallelism,
    required this.keyLength,
    required this.saltLength,
  });

  /// Parses the wire form
  /// `{"alg":"argon2id","v":19,"m_kib":65536,"t":3,"p":1,"dk_len":32,"salt_len":16}`.
  ///
  /// Throws [InvalidKdfParamsException] if a field is missing or has the
  /// wrong type. This does **not** check the values; call [validate].
  factory KdfParams.fromJson(Map<String, Object?> json) {
    final alg = json['alg'];
    if (alg is! String) {
      throw const InvalidKdfParamsException('kdf_params.alg must be a string');
    }
    int field(String key) {
      final value = json[key];
      if (value is int) {
        return value;
      }
      throw InvalidKdfParamsException('kdf_params.$key must be an integer');
    }

    return KdfParams(
      algorithm: alg,
      version: field('v'),
      memoryKib: field('m_kib'),
      iterations: field('t'),
      parallelism: field('p'),
      keyLength: field('dk_len'),
      saltLength: field('salt_len'),
    );
  }

  /// The v1 parameters: Argon2id v19, 64 MiB, 3 passes, 1 lane.
  static const KdfParams v1 = KdfParams(
    algorithm: 'argon2id',
    version: 19,
    memoryKib: 65536,
    iterations: 3,
    parallelism: 1,
    keyLength: keySize,
    saltLength: saltSize,
  );

  /// Lower bound on [memoryKib] (the v1 value).
  static const int minMemoryKib = 65536;

  /// Upper bound on [memoryKib] (1 GiB).
  static const int maxMemoryKib = 1048576;

  /// Lower bound on [iterations] (the v1 value).
  static const int minIterations = 3;

  /// Upper bound on [iterations].
  static const int maxIterations = 16;

  /// Upper bound on [parallelism].
  static const int maxParallelism = 4;

  /// `alg`: always `argon2id`.
  final String algorithm;

  /// `v`: Argon2 version, always 19 (0x13).
  final int version;

  /// `m_kib`: memory cost in KiB.
  final int memoryKib;

  /// `t`: number of passes.
  final int iterations;

  /// `p`: number of lanes.
  final int parallelism;

  /// `dk_len`: output length in bytes, always 32.
  final int keyLength;

  /// `salt_len`: salt length in bytes, always 16.
  final int saltLength;

  /// Rejects parameters this implementation will not run. The lower bounds
  /// stop a malicious server from downgrading the KDF; the upper bounds stop
  /// it from exhausting client memory. Mirrors `KDFParams.Validate` in the Go
  /// reference implementation.
  void validate() {
    if (algorithm != 'argon2id') {
      throw const InvalidKdfParamsException('kdf algorithm must be argon2id');
    }
    if (version != 19) {
      throw const InvalidKdfParamsException('argon2 version must be 19');
    }
    if (memoryKib < minMemoryKib || memoryKib > maxMemoryKib) {
      throw const InvalidKdfParamsException('argon2 memory out of range');
    }
    if (iterations < minIterations || iterations > maxIterations) {
      throw const InvalidKdfParamsException('argon2 time out of range');
    }
    if (parallelism < 1 || parallelism > maxParallelism) {
      throw const InvalidKdfParamsException('argon2 parallelism out of range');
    }
    if (keyLength != keySize) {
      throw const InvalidKdfParamsException('argon2 output must be 32 bytes');
    }
    if (saltLength != saltSize) {
      throw const InvalidKdfParamsException('argon2 salt must be 16 bytes');
    }
  }

  /// The wire form, with keys in the order used by the spec.
  Map<String, Object?> toJson() => <String, Object?>{
    'alg': algorithm,
    'v': version,
    'm_kib': memoryKib,
    't': iterations,
    'p': parallelism,
    'dk_len': keyLength,
    'salt_len': saltLength,
  };

  @override
  bool operator ==(Object other) =>
      other is KdfParams &&
      other.algorithm == algorithm &&
      other.version == version &&
      other.memoryKib == memoryKib &&
      other.iterations == iterations &&
      other.parallelism == parallelism &&
      other.keyLength == keyLength &&
      other.saltLength == saltLength;

  @override
  int get hashCode => Object.hash(
    algorithm,
    version,
    memoryKib,
    iterations,
    parallelism,
    keyLength,
    saltLength,
  );

  @override
  String toString() =>
      'KdfParams($algorithm v$version, m=$memoryKib KiB, t=$iterations, '
      'p=$parallelism)';
}
