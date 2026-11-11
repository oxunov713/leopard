# Leopard cryptographic specification (v1)

This document defines every cryptographic operation in Leopard precisely enough
that an independent implementation (the Dart package `packages/leopard_core`)
produces byte-identical output.

- Reference implementation: `backend/internal/crypto/crypto.go` (Go).
- Test vectors: `docs/test-vectors.json`. An implementation is conformant only
  if it reproduces every output in that file. `go test ./internal/crypto`
  fails if the Go implementation stops reproducing them.
- The vectors were additionally checked against an independent Python
  implementation (`cryptography` library) for every primitive except Argon2id.

The key words MUST, MUST NOT and SHOULD are used as in RFC 2119.

---

## 1. Goals and threat model

Leopard is a single-user password manager. The server is **zero-knowledge**:

| The server stores / sees | The server never sees |
|---|---|
| Item ciphertext, nonces, versions, timestamps | Item plaintext |
| The vault key wrapped under the master-password KEK and the recovery KEK | The vault key (VK) |
| Argon2id parameters and salt | The master password, the KEK |
| SHA-256 of the two auth keys (§6) | The recovery key |
| Ed25519 device public keys | Device private keys |
| The TOTP secret, encrypted with a server-held key (§7) | |
| The auth key itself, transiently, during a login or recovery request | |

An attacker who fully compromises the server or its database:

- cannot read items without also guessing the master password. The guess is
  offline, at Argon2id cost (64 MiB, 3 passes) per attempt, so **the strength of
  the master password is the final line of defence**;
- cannot use the recovery path: the recovery key has 128 bits of entropy;
- can delete or roll back data, and can refuse service. Roll-back of a single
  item to an older version of the *same* item is detectable only by a client
  that remembers the newer version number (the version is authenticated, §4);
- can serve a malicious web app if the web app is hosted on the same
  infrastructure. This is the inherent limit of any browser-based client. The
  phone app is not affected.

Out of scope for v1: vault-key rotation, changing the master password or
recovery key after setup, hiding item count/size/timing from the server.

---

## 2. Conventions

- `||` is byte-string concatenation. There are no length prefixes or
  separators unless stated; every concatenation in this spec is unambiguous
  because all variable parts have fixed lengths.
- String literals such as `"leopard/item/v1"` are their ASCII bytes with no
  terminating NUL.
- Integers are big-endian.
- **Wire encoding of binary:** base64url (RFC 4648 §5 alphabet `A–Z a–z 0–9 - _`)
  **without** `=` padding. Decoders MUST reject padding, characters outside
  the alphabet, and non-zero trailing bits. Example: bytes `fb ff fe 00 01`
  ↔ `-__-AAE`.
- **UUIDs** are the 36-character canonical text form, lower-case hex,
  `8-4-4-4-12`. Upper-case is rejected. When a UUID enters a cryptographic
  computation it is those 36 ASCII bytes, not the 16 raw bytes.
- The test-vector file writes binary as lower-case hex for readability; that
  is not the wire format.

### 2.1 Primitives

| Name | Definition |
|---|---|
| `HKDF(ikm, salt, info)` | HKDF-SHA256, RFC 5869, extract-then-expand, output length **32** bytes. "salt = empty" means a zero-length salt (equivalent, per RFC 5869, to 32 zero bytes). |
| `AEAD.Seal(key, nonce, pt, aad)` | AES-256-GCM, 32-byte key, **12**-byte nonce, **16**-byte tag. Returns `ciphertext || tag` (the nonce is *not* included). |
| `AEAD.Open(key, nonce, ct, aad)` | Inverse; fails if the tag does not verify. |
| `Argon2id` | RFC 9106, version 0x13 (19). |
| `X25519` | RFC 7748. An all-zero shared secret MUST be rejected. |
| `Ed25519` | RFC 8032 (pure Ed25519, no context, no prehash). |
| `SHA256` | FIPS 180-4. |
| `random(n)` | `n` bytes from the operating system CSPRNG. |

### 2.2 Sizes

| Value | Bytes |
|---|---|
| VK, KEK, item key, auth keys, QR transfer key | 32 |
| AES-GCM nonce | 12 |
| AES-GCM tag | 16 |
| Argon2id salt | 16 |
| Recovery key | 16 |
| QR session id (`sid`) | 16 |
| X25519 private / public key | 32 / 32 |
| Ed25519 seed / public key / signature | 32 / 32 / 64 |
| Wrapped VK (`nonce || ciphertext || tag`) | 12 + 32 + 16 = **60** |
| QR transfer ciphertext (`ciphertext || tag`) | 32 + 16 = **48** |
| Device-auth challenge nonce | 32 |
| Session token / poll token | 32 |

### 2.3 Domain-separation labels

| Label | Used as |
|---|---|
| `leopard/item/v1` | HKDF info: item key |
| `leopard/wrap/master/v1` | AEAD AAD: VK wrapped under the master KEK |
| `leopard/wrap/recovery/v1` | HKDF info: recovery KEK; **and** AEAD AAD: VK wrapped under it |
| `leopard/auth/v1` | HKDF info: master auth key |
| `leopard/auth/recovery/v1` | HKDF info: recovery auth key |
| `leopard/qr/v1` | HKDF info prefix: QR transfer key |
| `leopard/qr-approve/v1` | Signature prefix: QR approval |
| `leopard/verify/v1` | Hash prefix: verification code |
| `leopard/device-auth/v1` | Signature prefix: device login |
| `leopard/server/totp/v1` | Server only: AAD for the TOTP secret at rest |

---

## 3. Key hierarchy

```
master password ──Argon2id(salt)──► KEK ──┬─ AEAD ──► wrapped_vk_master   (stored on server)
                                          └─ HKDF("leopard/auth/v1") ──► master auth key ──SHA256──► verifier (server)

recovery key (16 random bytes) ─┬─ HKDF("leopard/wrap/recovery/v1") ──► RK-KEK ── AEAD ──► wrapped_vk_recovery (server)
                                └─ HKDF("leopard/auth/recovery/v1") ──► recovery auth key ──SHA256──► verifier (server)

VK (32 random bytes, generated on the phone)
 └─ HKDF("leopard/item/v1") ──► item key ── AEAD(per item) ──► item ciphertext (server)

device key (Ed25519, generated on the phone, private half never leaves it)
```

`VK = random(32)`. It is generated once, on the phone, at setup. It exists in
the clear only in client memory / the phone's secure storage.

---

## 4. Items

```
item_key = HKDF(ikm = VK, salt = empty, info = "leopard/item/v1")
```

There is one item key for the whole vault (the "per-item" separation comes
from the AAD below, not from distinct keys).

To write an item with id `item_id` at version `version`:

```
nonce      = random(12)                       # fresh for EVERY encryption
aad        = item_id (36 ASCII bytes) || uint64_be(version)      # 44 bytes
ciphertext = AEAD.Seal(item_key, nonce, plaintext, aad)          # len(plaintext) + 16
```

`nonce` and `ciphertext` are stored as separate fields.

**Version rule.** `version` is the version the item will have *after* the
write: `1` for a new item, `expected_version + 1` for an update (see
`PUT /v1/items/{id}` in `api.md`). A reader decrypts with the `id` and
`version` returned by the server. Binding both into the AAD means the server
cannot present one item's ciphertext as another item, or an old version's
ciphertext under a new version number, without decryption failing.

**Nonce rule.** A nonce MUST never repeat under the same key. With random
96-bit nonces the collision probability stays below 2⁻³² up to about 2³²
encryptions, far beyond a personal vault. Implementations MUST NOT derive the
nonce from the item id or version.

**Plaintext** is a UTF-8 JSON object. The server never parses it; the layout
is a client convention, defined in §14 ("Item plaintext schema v1"). Clients
MUST preserve unknown keys when re-saving. The encoded ciphertext is limited
to 256 KiB by the server.

Tombstones (deleted items) have no ciphertext.

Worked example (from the vectors): item `0f8fad5b-d9cb-469f-a165-70867728950e`,
version 7 gives the AAD

```
30663866616435622d643963622d343639662d613136352d373038363737323839353065 0000000000000007
```

---

## 5. Master password

```
password_bytes = UTF-8( NFC(password) )
salt = random(16)                                   # generated once at setup
KEK  = Argon2id(password = password_bytes, salt = salt,
                m = 65536 KiB (64 MiB), t = 3, p = 1, output = 32 bytes, version = 0x13)

nonce             = random(12)
wrapped_vk_master = nonce || AEAD.Seal(KEK, nonce, VK, aad = "leopard/wrap/master/v1")   # 60 bytes
```

**Password normalisation.** Before encoding, a client MUST convert the
password to Unicode Normalization Form C (NFC, UAX #15). The same visible
password can arrive as different code point sequences depending on the
keyboard or platform (`é` as U+00E9, or as U+0065 U+0301); without a common
form, a password created on the phone might not open the vault in a browser.
Rules:

- NFC only. A client MUST NOT apply compatibility normalisation (NFKC/NFKD),
  trimming, case folding or any other mapping: every code point that survives
  NFC is significant, including leading and trailing spaces.
- A string that is already NFC is encoded unchanged. That covers all ASCII
  passwords, precomposed Latin and Cyrillic letters, and sequences that have
  no composed form, such as Uzbek `oʻ` (U+006F U+02BB), which stays two code
  points. The decomposed pair U+0438 U+0306 becomes `й` (U+0439).
- Normalisation happens exactly once, immediately before UTF-8 encoding, in
  one place per implementation (`LeopardCrypto.passwordBytes` in
  `leopard_core`). The un-normalised string is never fed to the KDF.
- NFC is stable for assigned characters (Unicode stability policy), so
  implementations with different Unicode data versions agree on every
  password made of characters assigned in the older of the two versions.

The only non-ASCII password in the test vectors
(`master_password.password_utf8`) is already in NFC, so this rule does not
change any vector; `password_utf8_hex` is the expected `password_bytes`.

The KDF parameters travel with the vault as JSON so they can be raised later:

```json
{"alg":"argon2id","v":19,"m_kib":65536,"t":3,"p":1,"dk_len":32,"salt_len":16}
```

A client MUST validate parameters received from the server before using them
and refuse anything weaker than the v1 values (this stops a malicious server
from downgrading the KDF to make captured proofs cheap to brute-force) or
absurdly large: `alg = "argon2id"`, `v = 19`, `65536 ≤ m_kib ≤ 1048576`,
`3 ≤ t ≤ 16`, `1 ≤ p ≤ 4`, `dk_len = 32`, `salt_len = 16`.

---

## 6. Proof of knowledge (login without revealing the password)

The server must be able to check "this client knows the master password" (for
emergency web login) and "this client knows the recovery key" (for device
recovery) without ever being able to decrypt the vault.

```
master_auth_key       = HKDF(ikm = KEK, salt = empty, info = "leopard/auth/v1")
master_auth_verifier  = SHA256(master_auth_key)

recovery_auth_key      = HKDF(ikm = recovery_key, salt = empty, info = "leopard/auth/recovery/v1")
recovery_auth_verifier = SHA256(recovery_auth_key)
```

- **At setup** the phone sends only the two *verifiers*. The server stores them.
- **At login / recovery** the client recomputes the auth key and sends it as
  `proof`. The server computes `SHA256(proof)` and compares it to the stored
  verifier in constant time.

Why this is sound:

1. The auth key is derived from the KEK through HKDF with its own label. HKDF is
   a PRF, so learning `master_auth_key` reveals nothing about the KEK or about
   the AES key that wraps VK. The server therefore still cannot unwrap VK even
   after a successful login.
2. The server stores only a hash of the auth key, so a database leak does not
   yield a value that can be replayed as a login proof.
3. The proof is a bearer secret in transit; it is protected by TLS and by the
   second factor (TOTP, §7), and it is never logged.
4. A database leak *does* allow offline guessing of the master password (test a
   guess by running Argon2id and comparing hashes). That is already true of
   `wrapped_vk_master`, so the verifier adds no new attack; both cost one
   Argon2id evaluation per guess.
5. The recovery key is uniformly random (128 bits), so its verifier cannot be
   brute-forced at all.

To deny offline guessing to *unauthenticated* network attackers,
`GET /v1/auth/master/params` returns only the KDF parameters and salt.
`wrapped_vk_master` is released only by a successful
`POST /v1/auth/master/login` (correct proof **and** TOTP code).

---

## 7. TOTP (second factor for emergency web login)

RFC 6238 with HMAC-SHA1, 30-second step, 6 digits, T0 = 0. The server accepts
the current step and one step either side (±30 s clock skew). A step that has
been accepted, and every earlier step, is never accepted again (replay
protection).

The secret is 16–64 random bytes (20 recommended), generated on the phone at
setup, sent once to the server, and shown to the user as a standard
`otpauth://totp/...` URI (Base32 secret) for an authenticator app.

**Trade-off.** TOTP is a shared-secret scheme: the verifier needs the secret
in the clear to compute codes. This is the one place where the server holds a
usable secret. It is stored as

```
totp_secret_enc = nonce(12) || AEAD.Seal(SERVER_KEY, nonce, secret, aad = "leopard/server/totp/v1")
```

where `SERVER_KEY` is the 32-byte `LEOPARD_SERVER_KEY` environment variable,
kept outside the database. Consequences:

- a database-only leak does not expose the TOTP secret;
- an attacker with both the database and the server's environment can compute
  TOTP codes. They still need the master password to pass login or decrypt
  anything, so the vault's confidentiality never depends on TOTP. TOTP only
  protects against someone who has the master password but not the server.

---

## 8. Recovery key

```
recovery_key = random(16)
```

**Display format.** Base32 (RFC 4648 §6 alphabet `A–Z 2–7`), no padding: 16
bytes → 26 characters. Shown in groups of 4 separated by `-`; the last group
has 2 characters:

```
XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX        e.g. EAQS-EIZE-EUTC-OKBJ-FIVS-YLJO-F4
```

**Parsing.** Remove `-` and ASCII whitespace, upper-case, require exactly 26
characters of the alphabet, decode, and require that re-encoding yields the
same 26 characters (26 characters carry 130 bits; the 2 surplus bits must be
zero).

```
RK_KEK              = HKDF(ikm = recovery_key, salt = empty, info = "leopard/wrap/recovery/v1")
nonce               = random(12)
wrapped_vk_recovery = nonce || AEAD.Seal(RK_KEK, nonce, VK, aad = "leopard/wrap/recovery/v1")   # 60 bytes
```

The recovery key is shown once at setup and never stored by the app or sent
to the server.

**Recovery flow.** A new phone parses the recovery key, generates a new
Ed25519 device key, and calls `POST /v1/recovery/register-device` with
`proof = recovery_auth_key`. The server revokes every existing device and
session, registers the new device and returns `wrapped_vk_recovery`, which the
phone unwraps with `RK_KEK`.

Limitation: recovery cuts off the old phone's *access to the server*; it does
not rotate VK. If the old phone was stolen unlocked, treat stored passwords
as exposed.

---

## 9. Device key and device login

Each phone has an Ed25519 key pair generated on the device. The public key is
registered at setup (or recovery). The server assigns the `device_id` (UUID).

Login is challenge–response:

```
server:  challenge = random(32)                    # single-use, valid 60 s
phone:   message   = "leopard/device-auth/v1" || device_id (36 ASCII bytes) || challenge (32 bytes)   # 90 bytes
         signature = Ed25519.Sign(device_private_key, message)
```

The server verifies the signature against the registered public key and issues
a mobile session token. A challenge is consumed by the first verification
attempt, successful or not.

---

## 10. QR login: transferring VK to a browser

Roles: **B** = browser (web app), **P** = phone, **S** = server.

### 10.1 Protocol

1. **B** generates an ephemeral X25519 key pair `(b_priv, browser_pub)` and
   calls `POST /v1/qr {browser_pub}`.
2. **S** generates `sid = random(16)` and `poll_token = random(32)`, stores
   `browser_pub`, and returns both (plus an expiry 60 s away).
3. **B** displays a QR code containing the text

   ```
   leopard://qr?v=1&sid=<base64url(sid)>&pk=<base64url(browser_pub)>
   ```

   and the verification code (§10.3). `poll_token` is *not* in the QR code.
4. **P** scans the code and obtains `sid` and `browser_pub` **from the QR code
   itself**. It fetches `GET /v1/qr/{sid}/details` to show the user where the
   request came from, and MUST abort if the `browser_pub` reported by the
   server differs from the one in the QR code.
5. **P** shows the verification code; the user confirms it matches the browser.
6. **P** computes:

   ```
   (p_priv, phone_eph_pub) = fresh ephemeral X25519 key pair   # new for every approval
   shared = X25519(p_priv, browser_pub)                        # 32 bytes; reject if all zero
   key    = HKDF(ikm  = shared,
                 salt = sid,                                               # the 16 raw bytes
                 info = "leopard/qr/v1" || browser_pub || phone_eph_pub)   # 13 + 32 + 32 = 77 bytes
   nonce      = random(12)
   ciphertext = AEAD.Seal(key, nonce, VK, aad = sid)           # 48 bytes

   message   = "leopard/qr-approve/v1" || sid || browser_pub || phone_eph_pub || nonce || ciphertext
               #        21 bytes         16         32              32            12        48      = 161 bytes
   signature = Ed25519.Sign(device_private_key, message)
   ```

   and sends `{phone_eph_pub, nonce, ciphertext, signature}` to
   `POST /v1/qr/{sid}/approve`.
7. **S** rebuilds `message` from **its own** stored `sid` and `browser_pub`
   plus the submitted fields, verifies the signature against the approving
   device's registered key, checks the request is still pending and not
   expired, and records the approval.
8. **B** polls `GET /v1/qr/{sid}` with `poll_token`. Exactly one poll after
   approval returns `{session_token, phone_eph_pub, nonce, ciphertext}`; the
   request then becomes `consumed` and the payload is erased.
9. **B** computes

   ```
   shared = X25519(b_priv, phone_eph_pub)
   key    = HKDF(shared, salt = sid, info = "leopard/qr/v1" || browser_pub || phone_eph_pub)
   VK     = AEAD.Open(key, nonce, ciphertext, aad = sid)
   ```

   keeps VK in memory only, and discards `b_priv`.

### 10.2 Security properties

- **The server cannot read VK.** It never has `b_priv` or `p_priv`.
- **Forward secrecy.** Both X25519 keys are ephemeral; recording the traffic
  and later stealing a long-term key does not reveal VK.
- **Binding.** `sid` and both public keys are inputs to the key derivation, and
  `sid` is the AAD, so a payload cannot be replayed into another session or
  decrypted by another browser. The signature covers the same values plus the
  ciphertext, so the server only accepts an approval made by the registered
  device for exactly this request.
- **A photographed QR code is not enough.** Collecting the result needs
  `poll_token`, and decrypting it needs `b_priv`; neither is in the QR code.
- **One-time.** The approval can be collected once, within 60 s of approval.
- **What the signature does *not* give the browser.** The browser does not
  know the device public key and does not verify the signature; it is for the
  server's benefit. A malicious server could hand the browser a payload of its
  own making, but it cannot make the browser accept the *real* VK from anyone
  but the phone, and it never learns VK.

### 10.3 Verification code

The main residual risk is social: an attacker starts a login on *their own*
browser and tricks the user into scanning *their* QR code. The defence is
that both screens show the same short code, derived from values the attacker
cannot choose independently, together with the requesting IP and browser.

```
digest = SHA256("leopard/verify/v1" || sid || browser_pub)          # 17 + 16 + 32 bytes in
n      = (digest[0] << 16) | (digest[1] << 8) | digest[2]           # big-endian uint24
code   = decimal(n mod 1000000), left-padded with zeros to 6 digits
```

Both browser and phone MUST compute the code locally (the browser from the
`sid` it received and its own key; the phone from the QR code contents) and
SHOULD compare it with the server-supplied value. The user approves only if
the code on the phone equals the code on the screen in front of them.
(2²⁴ is not a multiple of 10⁶, so codes below 777216 are 17/16 times as likely
as the rest. That is irrelevant here: the code is a human-comparison aid, not
a secret.)

---

## 11. Sessions and tokens

- A session token is `random(32)`, sent as `Authorization: Bearer <base64url>`.
  The server stores only `SHA256(raw token bytes)`.
- The QR `poll_token` has the same form, sent as `X-Leopard-Poll-Token`.
- A web session token created by QR login is generated at the moment the
  browser collects it, so no usable web token is ever stored at rest.
- Web sessions expire after 300 s without a heartbeat and after 12 h in any
  case. Mobile sessions expire after 24 h without use; the phone silently
  re-authenticates with its device key.

On logout, lock, idle timeout or a 401 the web app MUST erase VK, the item
key, decrypted items and the session token from memory.

---

## 12. Setup, end to end

On the phone:

1. `VK = random(32)`; `recovery_key = random(16)`; `salt = random(16)`;
   Ed25519 device key pair; `totp_secret = random(20)`.
2. `KEK = Argon2id(password, salt, …)`; build `wrapped_vk_master` (§5).
3. `RK_KEK = HKDF(recovery_key, …)`; build `wrapped_vk_recovery` (§8).
4. Compute `master_auth_verifier` and `recovery_auth_verifier` (§6).
5. `POST /v1/setup` with the KDF parameters, salt, both wrapped keys, both
   verifiers, the TOTP secret and the device public key.
6. Show the recovery key (§8 format) and the TOTP enrolment QR code once.
7. Store VK and the device private key in the platform keystore. Erase the
   password, KEK, recovery key and auth keys from memory.

---

## 13. Test vectors

`docs/test-vectors.json` contains, with fixed inputs:

| Section | Checks |
|---|---|
| `encoding` | base64url without padding; SHA-256 sanity value |
| `item_key` | HKDF with empty salt |
| `item_encryption` | AAD layout, AES-256-GCM with AAD |
| `master_password` | UTF-8 handling of a non-ASCII password, Argon2id, VK wrap layout, auth key and verifier |
| `recovery_key` | Base32 display format, recovery KEK, VK wrap, auth key and verifier |
| `qr_transfer` | X25519 public keys and shared secret, HKDF with salt and binary info, transfer ciphertext, approval message and Ed25519 signature, verification code, QR URI |
| `device_auth` | Device-login message and signature |
| `totp` | RFC 6238 SHA-1 codes |

Ed25519 signatures are deterministic, so signature bytes must match exactly.
All inputs in the file are fixed patterns and MUST NOT be used as real keys.

The `item_encryption` plaintext is opaque bytes as far as the vector is
concerned. It was written before §14 existed and uses an older layout (no
`v`, a nested `fields` object); it is deliberately left unchanged so the
vector stays stable. A §14 reader treats it as an item of unknown version.

To regenerate after a deliberate, versioned protocol change:

```
cd backend && go test ./internal/crypto -update-vectors
```

Any change to an existing label or layout requires a new version suffix
(`/v2`), not an edit in place.

---

## 14. Item plaintext schema v1

This section defines the JSON object that is encrypted as an item's plaintext
(§4). It is purely a client convention: the server stores ciphertext and
cannot see, validate or migrate any of it. The reference implementation is
`packages/leopard_core/lib/src/models/vault_item.dart`.

### 14.1 Encoding

- The plaintext is one JSON object (RFC 8259), encoded as UTF-8 without a
  byte-order mark. Writers SHOULD emit it compactly (no insignificant
  whitespace) and in the key order shown below. Readers MUST NOT depend on
  key order or whitespace.
- Member names are case-sensitive and written exactly as shown (camelCase).
- Every item has the common members:

  | Member | Type | Meaning |
  |---|---|---|
  | `v` | integer | Schema version. Always `1` for this section. |
  | `type` | string | Discriminator: one of the type names in §14.2. |
  | `title` | string | Display name. May be empty. |
  | `createdAt` | string | When the item was first created. |
  | `updatedAt` | string | When the item's content last changed. |

- **Timestamps** are RFC 3339 strings. Writers MUST use UTC with the `Z`
  suffix and exactly three fractional digits (`2026-11-11T10:00:05.123Z`).
  Readers MUST accept any RFC 3339 timestamp that carries an explicit UTC
  offset, with any number of fractional digits, and MUST reject one without
  an offset. `createdAt` and `updatedAt` live inside the ciphertext on
  purpose: the server's own `updated_at` is unauthenticated metadata, and
  password-age checks must not depend on it. `updatedAt` is set by the client
  on every edit; `createdAt` never changes.
- **Required members** MUST be present with the stated JSON type, even when
  empty (`""`, `[]`). **Optional members** (marked `?`) are omitted when they
  have no value; writers MUST NOT emit `null` for them, and readers MUST treat
  `null` like absence.
- All secrets are JSON strings and are not transformed in any way (no
  trimming, no normalisation).

### 14.2 Item types

Members are listed in writing order, between `title` and `createdAt`.

| `type` | Members | Notes |
|---|---|---|
| `login` | `username`: string, `password`: string, `urls`: array of strings, `notes`: string, `totp`?: string | `urls` may be empty. `totp` is an `otpauth://` URI or a bare Base32 secret for *that site's* second factor (unrelated to §7). |
| `card` | `holder`: string, `number`: string, `expMonth`: integer 1–12, `expYear`: integer, four digits, `notes`: string | See the CVV rule below. `number` is stored as entered. |
| `wifi` | `ssid`: string, `password`: string, `security`: string, `notes`: string | `security` is `open`, `wep`, `wpa`, `wpa2` or `wpa3`; readers MUST keep any other string unchanged. `password` is empty for an open network. |
| `apiKey` | `service`: string, `key`: string, `secret`?: string, `notes`: string | `secret` is for services that issue a key id plus a secret. |
| `sshKey` | `privateKey`: string, `publicKey`?: string, `passphrase`?: string, `notes`: string | Keys are stored as their text file contents. |
| `secureNote` | `body`: string | |

**No card verification code.** There is no member for the CVV/CVC and there
never will be in v1. Writers MUST NOT store it under any name. Readers MUST
drop the members `cvv`, `cvv2`, `cvc`, `cvc2`, `cid`, `csc` and `securityCode`
from a `card` if they encounter them, and MUST NOT write them back.

### 14.3 Examples

```json
{"v":1,"type":"login","title":"Example","username":"aziz","password":"correct horse battery staple","urls":["https://example.com"],"notes":"","totp":"otpauth://totp/Example:aziz?secret=JBSWY3DPEHPK3PXP","createdAt":"2026-11-11T10:00:05.123Z","updatedAt":"2026-11-12T08:30:00.000Z"}
```

```json
{"v":1,"type":"card","title":"Visa","holder":"A. Example","number":"4111 1111 1111 1111","expMonth":9,"expYear":2031,"notes":"","createdAt":"2026-11-11T10:00:05.123Z","updatedAt":"2026-11-11T10:00:05.123Z"}
```

```json
{"v":1,"type":"wifi","title":"Home","ssid":"leopard-5g","password":"…","security":"wpa3","notes":"","createdAt":"2026-11-11T10:00:05.123Z","updatedAt":"2026-11-11T10:00:05.123Z"}
```

```json
{"v":1,"type":"apiKey","title":"Object storage","service":"S3","key":"AKIAEXAMPLE","secret":"…","notes":"read-only","createdAt":"2026-11-11T10:00:05.123Z","updatedAt":"2026-11-11T10:00:05.123Z"}
```

```json
{"v":1,"type":"sshKey","title":"Laptop","privateKey":"-----BEGIN OPENSSH PRIVATE KEY-----\n…","publicKey":"ssh-ed25519 AAAA… aziz@laptop","notes":"","createdAt":"2026-11-11T10:00:05.123Z","updatedAt":"2026-11-11T10:00:05.123Z"}
```

```json
{"v":1,"type":"secureNote","title":"Note","body":"…","createdAt":"2026-11-11T10:00:05.123Z","updatedAt":"2026-11-11T10:00:05.123Z"}
```

### 14.4 Reading rules and forward compatibility

1. If the plaintext is not a UTF-8 JSON object, the item is corrupt: report
   an error for that item and leave the stored ciphertext alone.
2. If `v` is not the integer `1`, or `type` is not one of the names above,
   the item was written by a newer (or pre-schema) client. The reader MUST
   keep the whole object verbatim, MUST NOT offer to edit it, and if it has
   to re-encrypt the item (for example after a version conflict) MUST write
   the object back unchanged. It MAY show `title` if that member is a string.
3. If `v` is `1` and `type` is known, every required member MUST be present
   with the right type; otherwise the item is malformed and is reported as an
   error (rule 1). A reader MUST NOT silently substitute defaults for
   secrets.
4. **Unknown members** of a known type MUST be preserved: kept in memory with
   their JSON values and written back, after the known members, whenever the
   item is saved. This is what lets a later minor revision add optional
   members without a version bump. The only exception is the forbidden card
   members of §14.2.
5. An unknown member can never override a known one: when writing, the known
   members win.

### 14.5 Versioning

Adding an optional member, or a new `type`, does not change `v`: old readers
preserve what they do not understand (rules 2 and 4). Anything an old reader
would misinterpret (renaming or retyping a member, changing its meaning,
making a new member required) needs `"v":2`, which v1 readers will refuse to
edit. This is independent of the `/v1` suffix of the cryptographic labels in
§2.3: the schema can change without touching the cryptography, and vice
versa.
