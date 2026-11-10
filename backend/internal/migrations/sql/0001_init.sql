-- Leopard schema v1.
-- The server stores only ciphertext, public keys, hashes and metadata.

CREATE TABLE vault (
    id                     smallint    PRIMARY KEY DEFAULT 1 CHECK (id = 1), -- singleton
    kdf_params             jsonb       NOT NULL,
    salt                   bytea       NOT NULL CHECK (octet_length(salt) = 16),
    wrapped_vk_master      bytea       NOT NULL CHECK (octet_length(wrapped_vk_master) = 60),
    wrapped_vk_recovery    bytea       NOT NULL CHECK (octet_length(wrapped_vk_recovery) = 60),
    master_auth_verifier   bytea       NOT NULL CHECK (octet_length(master_auth_verifier) = 32),
    recovery_auth_verifier bytea       NOT NULL CHECK (octet_length(recovery_auth_verifier) = 32),
    totp_secret_enc        bytea       NOT NULL,
    totp_last_step         bigint      NOT NULL DEFAULT 0,
    created_at             timestamptz NOT NULL
);

CREATE TABLE devices (
    id          uuid        PRIMARY KEY,
    label       text        NOT NULL,
    ed25519_pub bytea       NOT NULL CHECK (octet_length(ed25519_pub) = 32),
    created_at  timestamptz NOT NULL,
    last_seen   timestamptz,
    revoked_at  timestamptz
);

CREATE TABLE device_challenges (
    nonce_hash bytea       PRIMARY KEY,
    device_id  uuid        NOT NULL,
    expires_at timestamptz NOT NULL
);

CREATE TABLE sessions (
    id                   uuid        PRIMARY KEY,
    token_hash           bytea       UNIQUE, -- SHA-256(token); NULL until a QR-approved session is collected
    kind                 text        NOT NULL CHECK (kind IN ('web', 'mobile')),
    device_id            uuid        REFERENCES devices (id),
    client_info          jsonb       NOT NULL DEFAULT '{}',
    ip                   text        NOT NULL DEFAULT '',
    created_at           timestamptz NOT NULL,
    last_seen            timestamptz NOT NULL,
    idle_timeout_seconds integer     NOT NULL CHECK (idle_timeout_seconds > 0),
    revoked_at           timestamptz
);

CREATE TABLE qr_requests (
    sid             text        PRIMARY KEY,
    browser_pub     bytea       NOT NULL CHECK (octet_length(browser_pub) = 32),
    poll_token_hash bytea       NOT NULL,
    client_info     jsonb       NOT NULL DEFAULT '{}',
    ip              text        NOT NULL DEFAULT '',
    created_at      timestamptz NOT NULL,
    expires_at      timestamptz NOT NULL,
    status          text        NOT NULL CHECK (status IN ('pending', 'approved', 'consumed', 'rejected', 'expired')),
    phone_eph_pub   bytea,
    nonce           bytea,
    ciphertext      bytea,
    signature       bytea,
    device_id       uuid,
    approved_at     timestamptz,
    session_id      uuid        REFERENCES sessions (id) ON DELETE SET NULL
);

CREATE TABLE items (
    id         uuid        PRIMARY KEY,
    ciphertext bytea,                  -- NULL for tombstones
    nonce      bytea,
    version    bigint      NOT NULL CHECK (version >= 1),
    updated_at timestamptz NOT NULL,
    deleted_at timestamptz
);
CREATE INDEX items_updated_at_idx ON items (updated_at, id);

CREATE TABLE audit_log (
    id         bigserial   PRIMARY KEY,
    ts         timestamptz NOT NULL,
    event      text        NOT NULL,
    session_id uuid,
    device_id  uuid,
    ip         text        NOT NULL DEFAULT '',
    meta       jsonb       NOT NULL DEFAULT '{}'
);
CREATE INDEX audit_log_ts_idx ON audit_log (ts);
