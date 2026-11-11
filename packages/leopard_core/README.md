# leopard_core

The client-side core of Leopard, shared by `apps/mobile` and `apps/web`.
Pure Dart: no Flutter dependency, runs under `dart test`.

| Library part | What it is |
|---|---|
| `src/crypto/` | Every client primitive of [`docs/crypto-spec.md`](../../docs/crypto-spec.md), byte for byte |
| `src/models/` | `VaultItem` sealed hierarchy and its plaintext JSON (crypto-spec §14) |
| `src/api/` | Typed client for every endpoint in [`docs/api.md`](../../docs/api.md) |
| `src/generator/` | Password and passphrase generators, strength estimate |
| `src/audit/` | Weak / reused / old password checks over decrypted items |

Everything public is exported from `package:leopard_core/leopard_core.dart`.

The source of truth is the spec, the Go reference implementation
(`backend/internal/crypto/crypto.go`) and `docs/test-vectors.json`. This
package is conformant only while `test/test_vectors_test.dart` passes.

## Using it

```dart
import 'package:leopard_core/leopard_core.dart';

final crypto = LeopardCrypto(); // or LeopardCrypto(cryptography: FlutterCryptography())
final api = LeopardApiClient(baseUrl: Uri.parse('https://vault.example.com'));
```

### Injecting a faster crypto implementation

`LeopardCrypto` takes a `Cryptography` instance from
[`package:cryptography`](https://pub.dev/packages/cryptography). The default
is `Cryptography.instance`: pure Dart on the VM, Web Crypto in a browser.
Flutter apps should add `cryptography_flutter` and pass its
`FlutterCryptography` so that AES-GCM, X25519, Ed25519 and above all Argon2id
run natively.

Argon2id at the v1 parameters (64 MiB, 3 passes) takes on the order of a
second in pure Dart on a desktop VM and **blocks the calling isolate**. On a
phone, or compiled to JavaScript, expect several seconds: run `deriveKek` in
a background isolate / web worker, or inject a native implementation. Any
injected implementation must still pass the vector test; run the test suite
against it before shipping.

### Setup (phone)

```dart
final password = LeopardCrypto.passwordBytes(masterPassword);
final setup = await crypto.createVaultSetup(password: password);
final result = await api.setup(material: setup, deviceLabel: 'Pixel 9');
// Show once: formatRecoveryKey(setup.recoveryKey) and
// LeopardCrypto.totpProvisioningUri(secret: setup.totpSecret, accountName: ...)
// Store setup.vaultKey and setup.deviceKey.seed in the platform keystore,
// then: setup.destroy(); wipe(password);
```

### Items

```dart
final itemKey = await crypto.deriveItemKey(vaultKey);
final id = newUuid();
final item = LoginItem(title: 'Example', username: 'aziz', password: pw,
    createdAt: now, updatedAt: now);

// version = the version AFTER the write: 1 to create, expected + 1 to update.
final sealed = await crypto.encryptItem(
    itemKey: itemKey, itemId: id, version: 1, plaintext: item.encode());
await api.putItem(id: id, sealed: sealed, expectedVersion: 0);

final page = await api.listItems(since: lastServerTime); // store page.serverTime
for (final remote in page.items.where((i) => !i.deleted)) {
  final plain = await crypto.openItem(itemKey: itemKey, nonce: remote.nonce!,
      itemId: remote.id, version: remote.version, ciphertext: remote.ciphertext!);
  final decoded = VaultItem.decode(plain);
}
```

On `ConflictException` (`version_conflict`), re-fetch, merge, re-encrypt for
`e.serverVersion + 1` and retry with `expectedVersion: e.serverVersion`.

### QR login

Browser:

```dart
final key = await crypto.generateX25519KeyPair();
final qr = await api.createQrSession(browserPub: key.publicKey);
final text = QrUri(sid: qr.sid, browserPub: key.publicKey).toString(); // render
final code = await crypto.verifyCode(sid: qr.sid, browserPub: key.publicKey); // show
// poll about once a second:
final r = await api.pollQrSession(sid: qr.sid, pollToken: qr.pollToken);
if (r is QrPollApproved) {
  final vk = await crypto.qrOpenVaultKey(browserPrivateKey: key.privateKey,
      phoneEphPub: r.phoneEphPub, sid: qr.sid, nonce: r.nonce, ciphertext: r.ciphertext);
  key.destroy();
}
```

Phone:

```dart
final scanned = QrUri.parse(scannedText);          // sid and key come from the QR code
final details = await api.qrDetails(scanned.sid);
if (!constantTimeEquals(details.browserPub, scanned.browserPub)) abort();
final code = await crypto.verifyCode(sid: scanned.sid, browserPub: scanned.browserPub);
// show code + details.ip + details.clientInfo; the user confirms it matches the screen
final approval = await crypto.approveQrLogin(vaultKey: vk, deviceSeed: seed,
    sid: scanned.sid, browserPub: scanned.browserPub);
await api.approveQr(sid: scanned.sid, approval: approval);
```

The two checks on the phone (key from the QR code, not from the server; the
user compares the code) are the application's job. The API client cannot do
them for you. `test/api_client_test.dart` shows the whole flow, including
what happens when a server lies about the browser key.

## Security notes for callers

- **Randomness** comes only from `Random.secure()`
  (`src/crypto/secure_random.dart`). Nothing accepts an injected RNG.
- **Memory hygiene is best effort.** Functions wipe the intermediate keys
  they derive, and key-holding objects have `destroy()`. `wipe()` zeroes a
  `Uint8List`, but Dart's garbage collector may already have moved or copied
  the bytes, `package:cryptography` makes internal copies, and `String`s
  (passwords, tokens, decrypted item fields) cannot be wiped at all. Keep
  secrets as `Uint8List` where you can, wipe them when done, and drop all
  references to decrypted items on lock.
- **Tokens are held in memory only**, inside `LeopardApiClient`. The client
  drops its token on `logout()`, `clearSession()`, `close()` and on a 401 for
  an authenticated request. On `UnauthorizedException.sessionEnded` the app
  must lock and erase the vault key, item key and decrypted items.
- **Server responses are checked.** Sizes and encodings of every binary
  field, UUIDs, timestamps and enums are validated; anything else is a
  `MalformedResponseException`. KDF parameters from the server are validated
  against the v1 minimum before use, so a server cannot downgrade the KDF.
- **`https` only.** The client refuses `http://` base URLs unless
  `allowInsecureHttp` is set (local development).
- **Password normalisation is built in.** `LeopardCrypto.passwordBytes`
  converts the master password to Unicode NFC (crypto-spec §5, a MUST) with
  [`package:unorm_dart`](https://pub.dev/packages/unorm_dart) before UTF-8
  encoding, so "é" typed as one code point or as "e" + combining accent
  derives the same key. Always go through `passwordBytes`; never call
  `utf8.encode` on a master password yourself.
- **The audit is local.** `PasswordAuditor` compares passwords through
  SHA-256 digests that exist only during the call. Do not persist findings
  with anything derived from a password.
- **The strength estimate is a heuristic**, good for flagging weak
  passwords, not for certifying strong ones. It is not zxcvbn and it does
  not know breach corpora.

## Passphrase wordlist

`src/generator/eff_short_wordlist.dart` embeds the EFF Short Wordlist 1
(1296 words, 10.34 bits per word), © Electronic Frontier Foundation, licensed
[CC BY 3.0 US](https://creativecommons.org/licenses/by/3.0/us/). See the file
header for provenance.

## Development

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

Tests:

| File | What it covers |
|---|---|
| `test/test_vectors_test.dart` | **Conformance**: every section of `docs/test-vectors.json` against the pure-Dart implementation |
| `test/crypto_test.dart` | Round-trips and negative cases: tampering, wrong AAD / version / item id / label / session, malformed recovery keys and QR URIs, low-order X25519 points, bad signatures, KDF downgrade |
| `test/models_test.dart` | Item JSON layout, round-trips, forward compatibility, malformed input |
| `test/generator_test.dart` | Rejection sampling, charset and bias tests, wordlist integrity, strength estimate |
| `test/audit_test.dart` | Weak / reused / old checks |
| `test/api_client_test.dart` | Every endpoint against an in-memory server (`test/support/fake_server.dart`) with real crypto: QR login from both sides, master login, recovery, sync conflicts, error mapping |

The vector test reads `../../docs/test-vectors.json`, so run `dart test` from
this directory (which is what `dart test` and CI do).

`pubspec_overrides.yaml` and `pubspec.lock` are git-ignored: this is a
library, and the apps that depend on it own the lock file.
