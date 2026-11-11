# Leopard

A personal, single-user, zero-knowledge password manager.

- **Phone app (Android, Flutter)** — the root of trust. Holds the vault key and
  a device signing key, stores and syncs encrypted items.
- **Web app (Flutter Web)** — stores nothing. You log in by scanning a QR code
  with the phone (like Steam); the phone sends the vault key to the browser
  end-to-end encrypted, and the browser forgets it after 5 minutes idle.
- **API (Go)** — stores ciphertext, relays the QR handshake, manages sessions.
  It never sees the vault key, the master password or any plaintext.

## Status

| Phase | Scope | State |
|---|---|---|
| 1 | Crypto specification, Go reference implementation, test vectors | **done** |
| 2 | Go API: setup, device auth, QR login, items sync, sessions, emergency login, recovery, audit | **done** |
| 3 | `packages/leopard_core` (Dart crypto, item models, API client, generator, audit) | **done** |
| 3b | Android app | pending |
| 4 | Web app | pending |

## Layout

```
backend/                     Go module (API server)
  cmd/leopard-api/           entrypoint
  internal/crypto/           reference implementation of docs/crypto-spec.md
  internal/httpapi/          routes, middleware, handlers
  internal/store/            Store interface, Postgres (pgx) and in-memory implementations
  internal/migrations/       embedded SQL migrations
  internal/auth/             bearer tokens, server-key secret box
  internal/totp/             RFC 6238
  internal/ratelimit/        in-memory token buckets
  internal/config/           environment configuration
  Dockerfile                 distroless, static, non-root (Cloud Run)
packages/leopard_core/       shared pure-Dart client core: crypto, models, API client, generator, audit
apps/mobile/                 Android app (placeholder)
apps/web/                    web app (placeholder)
docs/
  crypto-spec.md             the protocol, byte for byte
  test-vectors.json          known-answer vectors every implementation must reproduce
  api.md                     every endpoint with examples
  deploy.md                  Cloud Run + Neon
```

## How it works (short version)

- The phone generates a random 32-byte **vault key (VK)**. Items are encrypted
  with AES-256-GCM under a key derived from VK; the item id and version are
  authenticated so ciphertexts cannot be swapped or silently rolled forward.
- VK is stored on the server only in wrapped form: once under a key derived
  from the **master password** (Argon2id, 64 MiB) and once under a key derived
  from a random **recovery key**.
- **QR login:** the browser shows an ephemeral X25519 public key as a QR code;
  the phone encrypts VK to it, signs the approval with its Ed25519 device key,
  and the server hands the result to the browser exactly once. Both screens
  show the same 6-digit code.
- **Emergency login** without the phone: master password + TOTP.
- **Lost phone:** the recovery key registers a new phone and revokes the old one.

Details and threat model: [`docs/crypto-spec.md`](docs/crypto-spec.md).

## Run the backend locally

Requires Go 1.24+.

Quickest, no database (data is lost on exit):

```sh
cd backend
export LEOPARD_DEV_MEMSTORE=1
export LEOPARD_SERVER_KEY=$(openssl rand -base64 32)
export LEOPARD_WEB_ORIGIN=http://localhost:5173
go run ./cmd/leopard-api
curl -s localhost:8080/healthz      # {"status":"ok"}
```

With Postgres (migrations are applied automatically at start):

```sh
createdb leopard
export DATABASE_URL='postgres://localhost/leopard?sslmode=disable'
export LEOPARD_SERVER_KEY=$(openssl rand -base64 32)   # keep it: it must stay the same for this database
go run ./cmd/leopard-api
```

All settings are listed in [`backend/.env.example`](backend/.env.example):

| Variable | Meaning |
|---|---|
| `DATABASE_URL` | Postgres URL (`sslmode=require` for Neon) |
| `PORT` | Listen port, default `8080` |
| `LEOPARD_WEB_ORIGIN` | Allowed browser origin(s) for CORS, comma separated |
| `LEOPARD_SERVER_KEY` | 32 random bytes, base64; encrypts the TOTP secret at rest |
| `LEOPARD_TRUST_PROXY` | `1` on Cloud Run: trust the last `X-Forwarded-For` entry |
| `LEOPARD_SETUP_TOKEN` | Optional: required header value for `POST /v1/setup` |
| `LEOPARD_DEV_MEMSTORE` | `1` = in-memory store, development only |

## Tests

```sh
cd backend
go vet ./...
go test ./...
```

The Postgres integration tests are skipped unless you point them at a
**disposable** database (they drop and recreate its schemas):

```sh
LEOPARD_TEST_DATABASE_URL='postgres://localhost/leopard_test?sslmode=disable' go test ./...
```

`go test ./internal/crypto` fails if the implementation no longer reproduces
`docs/test-vectors.json`.

The Dart client core has its own suite, which checks the same vectors:

```sh
cd packages/leopard_core
dart pub get
dart test
```

## Deploy

See [`docs/deploy.md`](docs/deploy.md) (Cloud Run `us-central1`, min-instances 0,
Neon Postgres, $1 budget alert).
