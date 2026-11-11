# apps/web — Leopard in the browser

The web app is the disposable end of a Leopard vault. It stores nothing: you
sign in by scanning a QR code with the phone, the phone sends the vault key
end-to-end encrypted, and the browser forgets it after five minutes without
activity.

- Flutter Web (stable), `flutter_bloc` Cubits, `go_router`, Clean Architecture
  feature folders like [`apps/mobile`](../mobile), dark theme only, English UI
- All cryptography comes from [`packages/leopard_core`](../../packages/leopard_core)
  with the default `Cryptography` instance: Web Crypto in the browser for
  AES-GCM, HKDF, HMAC, SHA-256 and X25519
- No CDN, no Google Fonts, no service worker, no analytics. CanvasKit and the
  fonts (Roboto, Roboto Mono) are part of the build, and CI fails if the
  build stops being self-contained

Protocol: [`docs/crypto-spec.md`](../../docs/crypto-spec.md). API: [`docs/api.md`](../../docs/api.md).

## What it does

| Area | Behaviour |
|---|---|
| QR login (start page) | Fresh X25519 key pair per code, `POST /v1/qr`, QR code and 6-digit verification code, 60 s countdown. The code and the QR text are computed in the browser and compared with the server's; a mismatch stops the login. `GET /v1/qr/{sid}` is polled once a second with `X-Leopard-Poll-Token`, one request at a time; errors back off 2, 4, 8, 10 s, a 429 waits for `Retry-After`. On approval the vault key is decrypted (crypto-spec §10.1 step 9) and the private key zeroed. An expired code is replaced automatically four times, then the page asks first, so a forgotten tab goes quiet. Rejected, expired, consumed and undecryptable approvals each have their own message |
| Emergency login | Master password + authenticator code. KDF parameters from the server (validated against the v1 minimum), Argon2id in the browser, the proof first, `wrapped_vk_master` only after the server accepts it, unwrap locally. One message for wrong password / wrong code / replayed code, because the server answers all three alike; 429 blocks the form for `Retry-After` |
| Vault | List with search and type filter; detail view with secrets masked until revealed (hidden again after 20 s); copy; add, edit, delete for login, card, Wi-Fi, API key, SSH key, secure note. No CVV field, by design |
| Sync | `GET /v1/items?since`, `PUT` with `expected_version`; a 409 asks "keep mine / take server"; a 410 offers to save the edit as a new item. Same rules and code as the phone app |
| Generator | Passwords (length, character classes, no look-alikes) and EFF-wordlist passphrases from `leopard_core`, with the exact entropy and a strength meter. Works **without logging in** (`#/login/generator`); signed in, "save as new item" hands the password to the item form |
| Session | See below |

## Run it

The API address is compiled in; there is no runtime configuration.

```sh
# 1. the API (see the root README), allowing this origin
cd backend
export LEOPARD_DEV_MEMSTORE=1
export LEOPARD_SERVER_KEY=$(openssl rand -base64 32)
export LEOPARD_WEB_ORIGIN=http://localhost:5173
go run ./cmd/leopard-api

# 2. the web app
cd apps/web
flutter pub get
flutter run -d chrome --web-port 5173 \
  --dart-define=LEOPARD_API_URL=http://localhost:8080
```

- **`LEOPARD_API_URL`** must be `https://…`. Plain `http://` is accepted for
  `localhost`, `127.0.0.1` and `[::1]` only. A build without it shows a
  configuration message instead of the app.
- **`LEOPARD_WEB_ORIGIN`** on the backend must contain the exact origin the
  page is served from (scheme, host, port; comma separated for several).
  Otherwise the browser blocks every API call (CORS) and the login page says
  it cannot reach the server.
- A vault must exist: set it up from the phone app first.

Release build (what CI runs):

```sh
flutter build web --release --no-web-resources-cdn --csp \
  --dart-define=LEOPARD_API_URL=https://your-api-host
```

`--no-web-resources-cdn` makes the build load CanvasKit from `canvaskit/` on
its own origin instead of `www.gstatic.com`; `web/flutter_bootstrap.js` sets
the same thing again and registers no service worker (the
`flutter_service_worker.js` that Flutter still emits is a stub whose only job
is to unregister an older one; nothing loads it). `--csp` keeps
dynamically generated code out of the compiled JavaScript. The output is
`build/web`: static files, any static host will do. Routes are in the URL
fragment (`/#/vault`), so the host needs no rewrite rules.

## Content-Security-Policy the build needs

The page has no inline script and no inline style of its own. This is the
tightest policy the Flutter engine works with; replace the API origin:

```
default-src 'none';
script-src 'self' 'wasm-unsafe-eval';
style-src 'self' 'unsafe-inline';
connect-src 'self' https://YOUR-API-ORIGIN;
font-src 'self';
img-src 'self';
base-uri 'self';
form-action 'none';
frame-ancestors 'none'
```

| Directive | Why |
|---|---|
| `script-src 'self'` | `flutter_bootstrap.js`, `main.dart.js`, `canvaskit/canvaskit.js`, all from the site itself |
| `'wasm-unsafe-eval'` | Compiling `canvaskit/canvaskit.wasm`. It allows WebAssembly compilation only, not `eval` |
| `style-src 'unsafe-inline'` | The Flutter engine inserts `<style>` elements for its host element and text fields. A static host cannot give it a nonce. Styles cannot run script |
| `connect-src 'self'` | `fetch` of `canvaskit.wasm`, the asset and font manifests and the bundled fonts |
| `connect-src <API>` | The only cross-origin requests the app makes |
| `font-src`, `img-src` | The favicon; fonts are read with `fetch`, the directive is there for completeness |

Nothing else is required: no `worker-src` (no workers, no service worker), no
`blob:` or `data:`, no `fonts.gstatic.com`, no `www.gstatic.com`.

Two things to know:

- Text in a script the bundled fonts do not cover (CJK, emoji, Arabic, …)
  would make the engine fetch a Noto font from `fonts.gstatic.com`. The policy
  blocks that, on purpose; such characters then show as empty boxes. Latin,
  Cyrillic and Greek are covered by Roboto.
- CI checks the static half of this: no inline script or style attribute in
  `index.html`, no `eval` or `new Function` in `main.dart.js` and
  `canvaskit.js`, CanvasKit and fonts present in the build. The policy as a
  whole has not been exercised in a browser from this repository (CI has no
  deployed site). On the first deployment open the console once: a violation
  is reported there with the directive that caused it.

Sensible companions, set by the host: `Referrer-Policy: no-referrer`,
`X-Content-Type-Options: nosniff`, `Strict-Transport-Security`,
`Cross-Origin-Opener-Policy: same-origin`,
`Permissions-Policy: camera=(), microphone=(), geolocation=()`, and
`Cache-Control: no-cache` for `index.html` and `flutter_bootstrap.js`.

## Security design

**Nothing persistent.** There is no `localStorage`, `sessionStorage`,
IndexedDB, cookie or Cache Storage use anywhere in the app, and no package
that provides one. The vault key and item key live in `VaultSession`, the
session token inside `leopard_core`'s API client; both are plain objects in
memory. A reload is a logout. Secrets are also kept out of the URL and out of
router state (a generated password travels to the item form through an
in-memory hand-off, because route data can reach the browser's session
history).

**When the session ends** (`core/session/session_cubit.dart`):

| Rule | Behaviour |
|---|---|
| Idle | 300 s without a key press, pointer press, movement or scroll. A warning strip counts down the last minute |
| Absolute | 12 h after login, whatever the activity |
| Tab in the background | 30 s hidden (the same rule as the phone app). Checked by timestamp when the tab comes back, because browsers suspend timers in background tabs |
| 401 | Any authenticated request answered with `session_revoked`, `session_expired`, `invalid_token` or `unauthenticated` |
| Logout button, tab close | Explicit |

Every one of them zeroes the vault key and item key, drops the token and the
decrypted items, clears the clipboard, and returns to the login page with a
line saying why. Except after a 401, the server is also told
(`POST /v1/sessions/logout`), so the token is dead even if a copy survived.
On tab close that request is best effort: a browser may drop it, and the
server then ends the session by its own idle timer.

**Heartbeats follow activity.** `POST /v1/sessions/heartbeat` is the only
thing that keeps a web session alive on the server. It is sent because of
user activity, at most every 30 s; activity inside that window is covered by
one heartbeat when the window ends. A page that is merely open sends nothing
and is locked by both sides.

**Emergency login and Argon2id.** Web Crypto has no Argon2, so the KEK is
derived by `package:cryptography`'s Dart implementation compiled to
JavaScript, on the page's own thread: 64 MiB, three passes. Compiled the way
a release build is (`dart2js -O4`) it took about 3 s on a GitHub Actions
runner; expect a few seconds on a laptop and more on a phone. (`flutter run`
and the `flutter test --platform chrome` step use the development compiler,
where the same derivation takes about a minute; that step prints its time.)
The implementation yields to the event
loop every 500 memory blocks, so the page keeps painting its "deriving the
key" state and elapsed time, but animations stutter and input is sluggish
until it is done. A web worker would fix that; it was left out deliberately:
it needs a second compiled entry point, a `worker-src` rule in the CSP and a
message protocol that carries the master password to another thread, none of
which could be tested in a browser here, for a wait of a few seconds on a
path that is used only when the phone is unavailable. The seam is `KeyDerivation` in
`core/security/key_derivation.dart`.

**Clipboard.** Copy uses `navigator.clipboard.writeText`; 30 s later, and on
every lock and logout, the clipboard is overwritten with an empty string. The
limits are the browser's:

- a page may write to the clipboard only while its tab is focused. If you
  switch tabs before the 30 s are over, the overwrite is refused; the app
  retries as soon as the tab is shown again;
- a page cannot check what is on the clipboard without asking for read
  permission (the app never does), so it overwrites unconditionally and will
  also clear something you copied elsewhere in the meantime;
- clipboard history (Windows `Win+V`, clipboard managers, phone keyboards)
  keeps its own copy that no page can reach;
- closing the tab before the 30 s are over leaves the secret there.

**What a browser client cannot give you** (crypto-spec §1): whoever serves
these files can serve different ones. Host the site somewhere you control,
and treat the phone as the trusted device. The QR approval is checked by the
server, not by the browser: the browser does not know the device key.

## Layout

```
lib/
  main.dart
  app/                     root widget, router, theme, shell, dependency wiring
  core/
    config/                AppConfig: LEOPARD_API_URL
    error/                 AppFailure and the error-to-text mapping
    network/               LeopardApi: the API calls the web makes, 401 announcement
    security/              clipboard, key derivation, password hand-off
    session/               VaultSession (the key in memory), SessionCubit (every lock rule)
    widgets/               secret field, secret value tile, strength meter, small shared widgets
  features/
    qr_login/              domain / data / presentation
    emergency_login/       domain / data / presentation
    vault/                 domain / data / presentation
    generator/             presentation
web/                       index.html, flutter_bootstrap.js, styles.css, favicon
assets/fonts/              Roboto (Apache 2.0), Roboto Mono (OFL 1.1), with licences
test/                      VM and widget tests; test/browser runs in Chrome
```

Cubits, repositories and domain code do not import Flutter or any browser
library, so their tests are plain Dart tests. The app has no `dart:js_interop`
or `package:web` code of its own: tab visibility and unload come from
Flutter's `AppLifecycleListener`, the clipboard from Flutter's `Clipboard`.

## Develop

```sh
cd apps/web
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --fatal-infos
flutter test
flutter test --platform chrome test/browser
```

| Path | Runs as | Covers |
|---|---|---|
| `test/core` | Dart VM, fake time | Session rules (idle, heartbeat throttling, 12 h, hidden tab, 401, logout), the API wrapper over a scripted HTTP client, clipboard clearing, configuration |
| `test/features/qr_login` | Dart VM | The QR state machine with fake time (countdown, renewal, backoff, 429, rejected / expired / consumed, stale answers); the repository with the real crypto, the test playing the phone |
| `test/features/emergency_login` | Dart VM | Proof-first login with real HKDF / AES-GCM, wrong credentials, replay, 429, wiped keys; one real Argon2id run |
| `test/features/vault`, `generator` | Dart VM | Sync, 409 / 410 handling, tampered or swapped ciphertext, item forms, generators |
| `test/widgets` | widget tests | The whole app with fakes below the repositories: login, vault, logout, 401, idle lock, public generator, narrow and wide layout |
| `test/browser` | Chrome (skipped on the VM) | `leopard_core` through Web Crypto and JS Argon2id against values from `docs/test-vectors.json` |

`pubspec.lock` is committed, so CI and every later build resolve the same
package versions; update it deliberately with `flutter pub upgrade`.

## Not in this version

- A web worker for Argon2id (see above).
- One-time codes generated from a login's TOTP secret; password health
  (the phone has it).
- Managing sessions or reading the audit log: the API reserves both for the
  phone.
- A WebAssembly (`--wasm`) build; the JavaScript build is the one that is
  tested.
