# apps/mobile — Leopard for Android (Flutter)

**Status: not started (phase 3).** This folder is a placeholder.

The phone is the root of trust. It will:

- create the vault: generate the vault key (VK), the recovery key, the Ed25519 device key and the TOTP secret, then call `POST /v1/setup`;
- keep VK and the device private key in the Android Keystore, unlocked by biometrics;
- store and sync encrypted items (`GET/PUT/DELETE /v1/items`), with an offline cache;
- scan the QR code shown by the web app, show the verification code, IP and browser details, and approve or reject the login (`/v1/qr/{sid}/details|approve|reject`);
- list and revoke active sessions and show the audit log.

All cryptography comes from `packages/leopard_core`, which must reproduce
`docs/test-vectors.json` exactly. Protocol: `docs/crypto-spec.md`. API: `docs/api.md`.
