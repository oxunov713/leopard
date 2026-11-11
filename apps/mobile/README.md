# apps/mobile — Leopard for Android

The phone is the root of trust of a Leopard vault: it creates the vault key,
keeps it, and hands it to a browser only after you approve a QR login.

- Package / application id: `uz.azizbek.leopard`, app name "Leopard"
- Android 8.0+ (minSdk 26), dark theme only, English UI
- Flutter (stable), `flutter_bloc` Cubits, `go_router`, Clean Architecture
- All cryptography comes from [`packages/leopard_core`](../../packages/leopard_core)
  (pure Dart, the implementation checked against `docs/test-vectors.json`)

Protocol: [`docs/crypto-spec.md`](../../docs/crypto-spec.md). API: [`docs/api.md`](../../docs/api.md).

## What it does

| Area | Behaviour |
|---|---|
| First run | Server address (https only) and optional setup token; master password with strength meter (at least 12 characters and about 60 bits); recovery key shown once, "I wrote it down", two groups typed back; TOTP enrolment (QR + secret, one code verified); then `POST /v1/setup` |
| Unlock | The phone's screen lock (PIN, pattern, password; a biometric only if Android offers one) on app open; master password always available as an explicit option, and the only gate on a phone with no screen lock (Argon2id in a background isolate) |
| Auto-lock | 30 s after the app leaves the screen the vault key is zeroed and every vault screen is closed |
| Vault | List, search, filter by type; view, add, edit, delete for login, card, Wi-Fi, API key, SSH key, secure note. No CVV field, by design |
| Sync | `GET /v1/items?since`, `PUT` with `expected_version`; a 409 asks "keep mine / take server"; a 410 offers to save the edit as a new item |
| Secrets on screen | Masked until tapped, hidden again after 20 s; copy clears the clipboard after 30 s |
| Generator | Passwords and EFF-wordlist passphrases, copy, "save as new item" |
| Health | Weak, reused and old passwords, computed on the phone |
| Web login | Scan the browser's QR code, compare the 6-digit code, approve with the phone's screen lock (master password if it has none) or reject |
| Sessions | Active web/mobile sessions, sign out one or all web sessions; server audit log |

## Layout

```
lib/
  main.dart
  app/                     root widget, router, theme, dependency wiring
  core/
    error/                 AppFailure and the error-to-text mapping
    lock/                  AppLockCubit: locked/unlocked state and auto-lock
    network/               RemoteVault: API access with device login and re-login
    security/              screen-lock authenticator, clipboard, key derivation (isolate)
    session/               VaultSession: the only holder of the vault key in memory
    storage/               DeviceStore on flutter_secure_storage
    widgets/               secret field, secret value tile, small shared widgets
  features/<name>/
    domain/                entities and repository interfaces (pure Dart)
    data/                  repository implementations
    presentation/          Cubit + pages
```

Features: `setup`, `unlock`, `vault`, `generator`, `health`, `qr_approve`,
`sessions`. Cubits, repositories and domain code do not import Flutter, so
their tests are plain Dart tests.

## Security design

**Where the keys live.** The vault key and the Ed25519 device seed are stored
with `flutter_secure_storage`: AES-GCM under a key wrapped by a key in the
Android Keystore. Next to them the phone keeps `wrapped_vk_master`, the
Argon2id salt and parameters (the same values the server holds) for the
master-password fallback. The recovery key and the master password are never
stored. Nothing decrypted is ever written to disk: there is no local item
cache, the vault is fetched after every unlock.

**The device-credential gate.** The phone is the key; the gate in front of
it is the phone's own screen lock. `local_auth` is called with
`biometricOnly: false`, so the Android system prompt accepts whatever the user
configured (PIN, pattern or password, plus a fingerprint or face if Android
offers one). A biometric is never required and nothing in the app checks for
one. The prompt appears on app open and resume, and before a QR approval.

Without a secure screen lock (`isDeviceSupported()` is false, or Android
answers `noCredentialsSet`) there is nothing to prompt for, so the master
password becomes the gate: unlock and QR approval both ask for it (Argon2id in
a background isolate, same path as the explicit "unlock with master password"
option, which exists on every phone). Setup and the Security screen show a
warning on such a phone recommending to set a screen lock; nothing else is
weakened or blocked.

Limits of this design that you should know about:

1. The gate is a check in the app, not a property of the key: the Keystore
   key that protects the stored vault key is not bound to user
   authentication. Someone who can run code as the app on an unlocked,
   rooted phone can read the stored keys without the screen-lock credential.
2. The strength of the gate is the strength of the screen lock. A short PIN
   on a phone someone has watched you unlock offers little; this is the
   deliberate trade-off of not requiring biometrics.
3. A phone with no screen lock is protected by the master password only, and
   the stored keys are exposed to anyone who has the unlocked phone.

`flutter_secure_storage` 11 can close the first gap
(`AndroidOptions.biometric(enforceBiometrics: ...)` binds the Keystore key to
user authentication). It changes when and how often the system prompt appears
and needs testing on real devices, so it is left as a follow-up; everything
it would touch is behind `SecureKeyValueStore` and `DeviceAuthenticator`.

**Auto-lock.** The countdown starts when the app is hidden, not when a system
dialog (screen-lock prompt, camera permission) covers it. A timer wipes the key
after 30 s; if Android froze the process and the timer never ran, the same
check happens with a timestamp when the app comes back.

**QR approval.** `sid` and the browser key are taken from the scanned code.
The app aborts if the server's `/details` names a different key, session or
verification code, or if the request is no longer pending. The code shown is
computed on the phone. Approve requires the phone's screen lock (any
credential Android accepts, never a biometric specifically); on a phone with
no screen lock it requires the master password instead.

**Android hardening.**

| Measure | Where |
|---|---|
| `FLAG_SECURE` and no recents screenshot | `MainActivity.kt` |
| `allowBackup="false"`, no cloud backup or device transfer | `AndroidManifest.xml`, `res/xml/data_extraction_rules.xml` |
| No cleartext traffic, user-installed CAs not trusted | `res/xml/network_security_config.xml`, `usesCleartextTraffic="false"`; the app and `leopard_core` also refuse non-https URLs |
| Keyboard does not learn, suggest, correct or autofill secrets | `core/widgets/secret_text_field.dart` |
| Clipboard entries flagged sensitive (Android 13+) and cleared after 30 s | `MainActivity.kt`, `core/security/platform_secret_clipboard.dart` |
| R8 on, release signing from an uncommitted file | `android/app/build.gradle.kts` |

## Not in this version

- **Recovery on a new phone** (`POST /v1/recovery/register-device`). A phone
  that loses its keys (reinstall, "Remove vault from this phone") cannot get
  back in from this app yet. `leopard_core` already has the client call.
- Offline access: there is no encrypted local cache.
- Changing the master password, and one-time codes generated from a login's
  TOTP secret.
- A custom launcher icon (the Flutter default is used).

## Develop

```sh
cd apps/mobile
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --fatal-infos
flutter test
flutter run            # a device or emulator with Android 8.0+
```

`pubspec.lock` is not in the repository yet. Commit the one produced by the
first `flutter pub get` so that builds are reproducible.

`android/gradlew`, `gradlew.bat` and `gradle-wrapper.jar` are git-ignored, as
in every project made by `flutter create`; the `flutter` tool puts its own
copies in place before it runs Gradle. `gradle-wrapper.properties` is
committed and pins the Gradle version.

Tests:

| Path | Runs as | Covers |
|---|---|---|
| `test/core`, `test/features` | plain Dart (`package:test`, `bloc_test`, `mocktail`) | Cubits for setup, unlock, vault sync (409, 410, rollback), QR approval, sessions, auto-lock; repositories with the real crypto against in-memory servers |
| `test/widgets` | widget tests | Setup, unlock, vault, QR approval screens; routing by lock state; hardened secret fields |

## Release build

1. Create a keystore and `android/key.properties` (git-ignored, never commit
   either):

   ```properties
   storeFile=/absolute/path/to/leopard-release.jks
   storePassword=...
   keyAlias=leopard
   keyPassword=...
   ```

2. Build with Dart obfuscation and keep the symbols for stack traces:

   ```sh
   flutter build apk --release --obfuscate --split-debug-info=build/symbols
   ```

Without `key.properties` a release build is signed with the debug key so that
`flutter run --release` works. Do not install or share such a build as the
real app.
