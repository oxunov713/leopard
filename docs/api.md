# Leopard API (v1)

JSON over HTTPS. All application endpoints are under `/v1`. The cryptography
behind the fields is defined in [`crypto-spec.md`](crypto-spec.md).

## Conventions

- **Binary fields** are base64url **without padding**. Sizes below are of the
  decoded bytes. Wrong size or encoding → `400 invalid_request`.
- **Timestamps** are RFC 3339 UTC with up to microsecond precision.
- **UUIDs** are lower-case canonical text.
- **Request bodies** must be `Content-Type: application/json`, a single JSON
  object, no unknown fields. Limit 16 KiB (512 KiB for `PUT /v1/items/{id}`).
- **Authentication:** `Authorization: Bearer <session_token>`.
  - *any session* — a web or mobile session.
  - *mobile session* — a session obtained by device login. A web session gets
    `403 mobile_only`.
- **Errors** always look like:

  ```json
  {"error": {"code": "version_conflict", "message": "expected_version does not match the stored version"}}
  ```

### Common error codes

| HTTP | code | Meaning |
|---|---|---|
| 400 | `invalid_request`, `invalid_json` | Malformed input |
| 401 | `unauthenticated`, `invalid_token` | No / unknown bearer token |
| 401 | `session_revoked`, `session_expired` | Session was revoked, or idle too long. The client must lock and wipe keys |
| 403 | `mobile_only` | Endpoint needs a mobile session |
| 403 | `origin_not_allowed` | Request carried an `Origin` not in `LEOPARD_WEB_ORIGIN` |
| 404 | `not_found` | No such endpoint |
| 413 | `body_too_large` | |
| 415 | `unsupported_media_type` | Body without `application/json` |
| 429 | `rate_limited` | See `Retry-After` (seconds) |
| 500 | `internal` | Details are in the server log only |

### Rate limits (per client IP; IPv6 per /64)

| Endpoint | Limit |
|---|---|
| `POST /v1/setup` | 5 / hour |
| `POST /v1/auth/device/*` | 20 / minute |
| `POST /v1/qr` | 10 / minute |
| `GET /v1/qr/{sid}` | 90 / minute (poll about once a second) |
| `GET /v1/auth/master/params` | 5 / 5 minutes |
| `POST /v1/auth/master/login` | 5 / 15 minutes per IP **and** 10 / 15 minutes globally |
| `POST /v1/recovery/register-device` | 5 / hour per IP **and** 10 / hour globally |
| everything else | 120 / minute |

Limits are token buckets (the number is both the burst and the refill per period).

### Response headers on every response

`Strict-Transport-Security: max-age=63072000; includeSubDomains`,
`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
`Content-Security-Policy: default-src 'none'; frame-ancestors 'none'`,
`Referrer-Policy: no-referrer`, `Cache-Control: no-store`, `X-Request-Id`.

### CORS

Only origins listed in `LEOPARD_WEB_ORIGIN` are allowed (exact match). Allowed
request headers: `Authorization`, `Content-Type`, `X-Leopard-Poll-Token`.
Cookies/credentials are never used.

---

## Health

### `GET /healthz`

No auth. Pings the database.

```json
200 {"status": "ok"}
503 {"status": "unavailable"}
```

---

## Setup

### `POST /v1/setup`

One-time vault initialisation from the phone. Registers the first device.
If the server was started with `LEOPARD_SETUP_TOKEN`, the request must carry
`X-Leopard-Setup-Token: <token>`.

Request:

```json
{
  "kdf_params": {"alg": "argon2id", "v": 19, "m_kib": 65536, "t": 3, "p": 1, "dk_len": 32, "salt_len": 16},
  "salt": "EBESExQVFhcYGRobHB0eHw",
  "wrapped_vk_master": "<60 bytes>",
  "wrapped_vk_recovery": "<60 bytes>",
  "master_auth_verifier": "<32 bytes: SHA-256(master auth key)>",
  "recovery_auth_verifier": "<32 bytes: SHA-256(recovery auth key)>",
  "totp_secret": "<16-64 bytes, raw secret>",
  "device": {"label": "Pixel 9", "ed25519_pub": "<32 bytes>"}
}
```

Response `201`:

```json
{"device_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7", "created_at": "2026-11-11T10:00:00Z"}
```

Errors: `409 already_initialised` (a vault exists; nothing is changed),
`403 setup_token_required`, `400 invalid_request` (including KDF parameters
weaker than the v1 minimum).

---

## Device login (mobile)

### `POST /v1/auth/device/challenge`

```json
{"device_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7"}
```

Response `200` (also returned for unknown devices, so ids cannot be probed):

```json
{"nonce": "<32 bytes>", "expires_at": "2026-11-11T10:01:00Z"}
```

### `POST /v1/auth/device/verify`

`signature` = Ed25519 over `"leopard/device-auth/v1" || device_id || nonce`.

```json
{"device_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7", "nonce": "<32 bytes>", "signature": "<64 bytes>"}
```

Response `200`:

```json
{
  "session_token": "rXlZajQM1gs9cGoWGG8mnUHwC5TsxcaihSk3xS7uPIs",
  "session_id": "5f0c0d3e-1c0a-4b54-9d39-0f2f8c5b3a11",
  "kind": "mobile",
  "idle_timeout_seconds": 86400
}
```

Errors: `401 device_auth_failed` for every failure (unknown or revoked device,
unknown / expired / already-used nonce, bad signature). The nonce is consumed
by the attempt either way; request a new challenge to retry.

---

## QR login

Flow: browser `POST /v1/qr` → shows QR → phone `GET …/details` → phone
`POST …/approve` → browser `GET /v1/qr/{sid}` collects once.

### `POST /v1/qr`

No auth (called by the browser). `client_info` is an optional JSON object
(≤ 2 KiB) shown to the user on the phone; it is untrusted, display-only.

```json
{"browser_pub": "<32 bytes X25519>", "client_info": {"platform": "Linux", "browser": "Firefox"}}
```

Response `201`:

```json
{
  "sid": "VlzLuUi5e5gU1cCAVI0A5Q",
  "poll_token": "rXlZajQM1gs9cGoWGG8mnUHwC5TsxcaihSk3xS7uPIs",
  "expires_at": "2026-11-11T10:01:00Z",
  "verify_code": "459154",
  "qr_uri": "leopard://qr?v=1&sid=VlzLuUi5e5gU1cCAVI0A5Q&pk=<browser_pub>"
}
```

Render `qr_uri` as the QR code. Keep `poll_token` in memory; it must not
appear in the QR code. The request can be approved until `expires_at` (60 s).

### `GET /v1/qr/{sid}`

Polled by the browser. Requires header `X-Leopard-Poll-Token: <poll_token>`.
An unknown `sid` and a wrong token both give `404 qr_not_found`.

Response `200` while waiting, or after a terminal state:

```json
{"status": "pending", "expires_at": "2026-11-11T10:01:00Z"}
```

`status` is one of `pending`, `rejected`, `expired`, `consumed`.

Response `200`, **exactly once**, after the phone approved:

```json
{
  "status": "approved",
  "session_token": "<web session token>",
  "session_id": "0b0f4c58-9d5e-4b8a-8a43-0e6c1c7d1f02",
  "kind": "web",
  "idle_timeout_seconds": 300,
  "phone_eph_pub": "<32 bytes>",
  "nonce": "<12 bytes>",
  "ciphertext": "<48 bytes>"
}
```

The browser decrypts the vault key from `phone_eph_pub`, `nonce`, `ciphertext`
(crypto-spec §10). Every later poll returns `{"status": "consumed"}` with no
token and no payload. An approval not collected within 60 s becomes `expired`.

### `GET /v1/qr/{sid}/details` — mobile session

What the phone shows before asking the user to approve.

```json
{
  "sid": "VlzLuUi5e5gU1cCAVI0A5Q",
  "status": "pending",
  "browser_pub": "<32 bytes>",
  "client_info": {"user_agent": "Mozilla/5.0 …", "reported": {"platform": "Linux", "browser": "Firefox"}},
  "ip": "203.0.113.50",
  "created_at": "2026-11-11T10:00:00Z",
  "expires_at": "2026-11-11T10:01:00Z",
  "verify_code": "459154"
}
```

The phone must take `browser_pub` from the QR code and abort if this value
differs.

### `POST /v1/qr/{sid}/approve` — mobile session

`signature` = Ed25519 (device key of the calling session) over
`"leopard/qr-approve/v1" || sid || browser_pub || phone_eph_pub || nonce || ciphertext`.

```json
{"phone_eph_pub": "<32 bytes>", "nonce": "<12 bytes>", "ciphertext": "<48 bytes>", "signature": "<64 bytes>"}
```

Response `200`:

```json
{"status": "approved", "session_id": "0b0f4c58-9d5e-4b8a-8a43-0e6c1c7d1f02"}
```

`session_id` is the web session that will become active when the browser
collects it; the phone can revoke it with `DELETE /v1/sessions/{id}`.

Errors: `403 bad_signature`, `410 qr_expired`, `409 qr_not_pending` (already
approved, rejected or consumed), `404 qr_not_found`.

### `POST /v1/qr/{sid}/reject` — mobile session

No body. Response `200 {"status": "rejected"}`. Errors as for approve.

---

## Emergency web login (master password + TOTP)

### `GET /v1/auth/master/params`

No auth, hard rate limit.

```json
{"kdf_params": {"alg": "argon2id", "v": 19, "m_kib": 65536, "t": 3, "p": 1, "dk_len": 32, "salt_len": 16},
 "salt": "EBESExQVFhcYGRobHB0eHw"}
```

`404 not_initialised` if there is no vault. The client must validate
`kdf_params` (crypto-spec §5) before running the KDF.

### `POST /v1/auth/master/login`

`proof` = master auth key = `HKDF(KEK, info "leopard/auth/v1")`.

```json
{"totp_code": "492039", "proof": "<32 bytes>", "client_info": {"browser": "Firefox"}}
```

Response `200`:

```json
{
  "session_token": "<web session token>",
  "session_id": "c1a2d3e4-0000-4000-8000-000000000001",
  "kind": "web",
  "idle_timeout_seconds": 300,
  "wrapped_vk_master": "<60 bytes>"
}
```

The client unwraps `wrapped_vk_master` with the KEK. Errors:
`401 invalid_credentials` (identical whether the proof, the code or both were
wrong, or the code was already used), `429 rate_limited`.

---

## Recovery

### `POST /v1/recovery/register-device`

`proof` = recovery auth key = `HKDF(recovery_key, info "leopard/auth/recovery/v1")`.

```json
{"proof": "<32 bytes>", "device": {"label": "New phone", "ed25519_pub": "<32 bytes>"}}
```

Response `201`:

```json
{
  "device_id": "2d4b1b1e-6f0a-4a39-8a51-1d5f3c9f7e10",
  "wrapped_vk_recovery": "<60 bytes>",
  "kdf_params": {"alg": "argon2id", "v": 19, "m_kib": 65536, "t": 3, "p": 1, "dk_len": 32, "salt_len": 16},
  "salt": "EBESExQVFhcYGRobHB0eHw"
}
```

Side effects: **every existing device and every session is revoked**, pending
QR requests are expired. The new phone then logs in with device
challenge–response. Errors: `401 invalid_credentials`, `429 rate_limited`.

---

## Items — any session

### `GET /v1/items?since=<rfc3339>`

Returns items whose `updated_at` is strictly later than `since`, including
tombstones, ordered by `updated_at`. Omit `since` for a full sync. Store
`server_time` and send it as the next `since`.

```json
{
  "items": [
    {"id": "0f8fad5b-d9cb-469f-a165-70867728950e", "version": 3, "updated_at": "2026-11-11T10:00:05.123456Z",
     "deleted": false, "ciphertext": "<bytes>", "nonce": "<12 bytes>"},
    {"id": "9b2e7f10-3c4d-4e5f-8a6b-7c8d9e0f1a2b", "version": 4, "updated_at": "2026-11-11T10:00:09Z",
     "deleted": true, "deleted_at": "2026-11-11T10:00:09Z"}
  ],
  "server_time": "2026-11-11T10:00:10Z"
}
```

### `PUT /v1/items/{id}`

Create or replace. The client chooses the UUID. `expected_version` is the
version the client last saw: `0` to create. The stored version becomes
`expected_version + 1`, and **that** is the version the client must have used
in the AEAD associated data (crypto-spec §4).

```json
{"ciphertext": "<17 bytes .. 256 KiB>", "nonce": "<12 bytes>", "expected_version": 2}
```

Response `201` (created) or `200` (replaced):

```json
{"id": "0f8fad5b-d9cb-469f-a165-70867728950e", "version": 3, "updated_at": "2026-11-11T10:00:05.123456Z", "deleted": false}
```

`409` when `expected_version` is stale (or `0` for an id that exists). Nothing
is written; re-fetch, merge, re-encrypt with the new version and retry:

```json
{
  "error": {"code": "version_conflict", "message": "expected_version does not match the stored version"},
  "current": {"id": "0f8fad5b-d9cb-469f-a165-70867728950e", "version": 3, "updated_at": "2026-11-11T10:00:05.123456Z", "deleted": false}
}
```

Other errors: `404 item_not_found` (`expected_version > 0` for an unknown id),
`410 item_deleted` (the id is a tombstone; ids are never reused).

### `DELETE /v1/items/{id}`

Soft delete: the ciphertext is erased and a tombstone with `version + 1` remains.

```json
{"expected_version": 3}
```

Response `200`:

```json
{"id": "0f8fad5b-d9cb-469f-a165-70867728950e", "version": 4, "updated_at": "2026-11-11T10:00:09Z", "deleted": true}
```

Errors: `409 version_conflict`, `404 item_not_found`, `410 item_deleted`.

---

## Sessions

### `POST /v1/sessions/heartbeat` — any session

No body. The web app calls this on user activity. For web sessions this is the
**only** request that resets the idle timer (300 s); other requests are served
but do not count as activity. Web sessions also end 12 h after creation.

```json
{"session_id": "0b0f4c58-9d5e-4b8a-8a43-0e6c1c7d1f02", "kind": "web", "idle_timeout_seconds": 300,
 "expires_at": "2026-11-11T10:05:00Z", "server_time": "2026-11-11T10:00:00Z"}
```

`401 session_revoked` / `401 session_expired` → lock immediately and wipe keys.

### `POST /v1/sessions/logout` — any session

No body. Revokes the calling session. `200 {"status": "logged_out"}`.

### `GET /v1/sessions` — mobile session

Live sessions, newest first.

```json
{
  "sessions": [
    {"id": "0b0f4c58-9d5e-4b8a-8a43-0e6c1c7d1f02", "kind": "web", "device_id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
     "client_info": {"user_agent": "Mozilla/5.0 …", "reported": {"browser": "Firefox"}}, "ip": "203.0.113.50",
     "created_at": "2026-11-11T10:00:00Z", "last_seen": "2026-11-11T10:02:00Z", "idle_timeout_seconds": 300,
     "expires_at": "2026-11-11T10:07:00Z", "current": false}
  ],
  "server_time": "2026-11-11T10:02:30Z"
}
```

For a web session created by QR login, `device_id` is the device that approved
it; for one created by master-password login it is `null`.

### `DELETE /v1/sessions/{id}` — mobile session

Revokes a session (remote logout). `200 {"status": "revoked", "id": "…"}`,
`404 session_not_found` if it is not live.

---

## Audit log

### `GET /v1/audit?limit=100&before=<id>` — mobile session

Newest first. `limit` 1–500 (default 100). Pass `next_before` as `before` for
the next page; `null` means there is no more.

```json
{
  "entries": [
    {"id": 42, "ts": "2026-11-11T10:00:07Z", "event": "qr_approved", "session_id": "5f0c0d3e-…", "device_id": "7c9e6679-…",
     "ip": "198.51.100.7", "meta": {"sid": "VlzLuUi5e5gU1cCAVI0A5Q", "web_session_id": "0b0f4c58-…", "browser_ip": "203.0.113.50"}}
  ],
  "next_before": null
}
```

Events: `vault_setup`, `setup_denied`, `device_auth_ok`, `device_auth_failed`,
`qr_created`, `qr_approved`, `qr_approve_failed`, `qr_rejected`, `qr_consumed`,
`master_login_ok`, `master_login_failed`, `recovery_device_registered`,
`recovery_failed`, `session_revoked`, `session_expired`, `logout`,
`item_deleted`. The log never contains tokens, proofs, keys or ciphertext.
