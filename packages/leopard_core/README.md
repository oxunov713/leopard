# packages/leopard_core — shared Dart crypto and API client

**Status: not started (phase 3).** This folder is a placeholder.

A pure-Dart package used by both `apps/mobile` and `apps/web`:

- the cryptography in `docs/crypto-spec.md`: HKDF-SHA256, AES-256-GCM, Argon2id, X25519, Ed25519, the recovery-key Base32 format, the QR transfer and the verification code;
- item models and their JSON plaintext format;
- a typed client for the API in `docs/api.md`.

**Acceptance test:** a Dart test must load `docs/test-vectors.json` and reproduce every
output byte for byte. The Go reference implementation is
`backend/internal/crypto`; the vectors were also cross-checked against an
independent Python implementation.
