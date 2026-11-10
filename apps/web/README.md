# apps/web — Leopard web app (Flutter Web)

**Status: not started (phase 4).** This folder is a placeholder.

The web app never stores anything. It will:

- generate an ephemeral X25519 key pair, call `POST /v1/qr` and show the QR code (`qr_uri`) with the 6-digit verification code;
- poll `GET /v1/qr/{sid}` with the poll token, then decrypt the vault key sent by the phone and hold it **in memory only**;
- read and edit items with the session token;
- send `POST /v1/sessions/heartbeat` on user activity and lock itself (wipe the key) after 300 s idle, on 401, or when the tab closes;
- offer the emergency login (master password + TOTP) when the phone is unavailable.

All cryptography comes from `packages/leopard_core`. Protocol: `docs/crypto-spec.md`. API: `docs/api.md`.
