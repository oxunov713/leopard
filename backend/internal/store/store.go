// Package store defines the persistence interface of the Leopard API and its
// two implementations: Postgres (pgx) and an in-memory store used by tests
// and local development.
//
// Nothing stored here is secret key material in the clear: item bodies and the
// vault key are ciphertext produced on the client, tokens are stored as
// SHA-256 hashes, and the TOTP secret is encrypted with the server key before
// it reaches the store.
package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

var (
	ErrNotFound        = errors.New("store: not found")
	ErrVaultExists     = errors.New("store: vault already initialised")
	ErrVersionConflict = errors.New("store: version conflict")
	ErrGone            = errors.New("store: item deleted")
	ErrQRState         = errors.New("store: qr request is not in the required state")
	ErrQRExpired       = errors.New("store: qr request expired")
)

// Session kinds.
const (
	KindWeb    = "web"
	KindMobile = "mobile"
)

// QR request states.
const (
	QRPending  = "pending"
	QRApproved = "approved"
	QRConsumed = "consumed"
	QRRejected = "rejected"
	QRExpired  = "expired"
)

// Vault is the singleton vault row.
type Vault struct {
	KDFParams            json.RawMessage
	Salt                 []byte
	WrappedVKMaster      []byte
	WrappedVKRecovery    []byte
	MasterAuthVerifier   []byte // SHA-256(master auth_key)
	RecoveryAuthVerifier []byte // SHA-256(recovery auth_key)
	TOTPSecretEnc        []byte // encrypted with LEOPARD_SERVER_KEY
	TOTPLastStep         int64  // last accepted TOTP step (replay protection)
	CreatedAt            time.Time
}

// Device is a phone holding an Ed25519 device key.
type Device struct {
	ID         string
	Label      string
	Ed25519Pub []byte
	CreatedAt  time.Time
	LastSeen   *time.Time
	RevokedAt  *time.Time
}

// Session is a bearer-token session. The token itself is never stored.
type Session struct {
	ID                 string
	Kind               string
	DeviceID           *string // mobile: the authenticating device; web via QR: the approving device
	ClientInfo         json.RawMessage
	IP                 string
	CreatedAt          time.Time
	LastSeen           time.Time
	IdleTimeoutSeconds int
	RevokedAt          *time.Time
	// Active is false for a web session that has been approved by the phone
	// but whose token has not been issued to the browser yet.
	Active bool
}

// QRRequest is one QR login attempt.
type QRRequest struct {
	SID           string // base64url of 16 random bytes
	BrowserPub    []byte
	PollTokenHash []byte
	ClientInfo    json.RawMessage
	IP            string
	CreatedAt     time.Time
	ExpiresAt     time.Time
	Status        string
	PhoneEphPub   []byte
	Nonce         []byte
	Ciphertext    []byte
	Signature     []byte
	DeviceID      *string
	ApprovedAt    *time.Time
	SessionID     *string
}

// QRApproval is what the phone submits.
type QRApproval struct {
	PhoneEphPub []byte
	Nonce       []byte
	Ciphertext  []byte
	Signature   []byte
	DeviceID    string
}

// Item is an encrypted vault item or its tombstone.
type Item struct {
	ID         string
	Ciphertext []byte
	Nonce      []byte
	Version    int64
	UpdatedAt  time.Time
	DeletedAt  *time.Time
}

// AuditEntry is one audit log line.
type AuditEntry struct {
	ID        int64
	TS        time.Time
	Event     string
	SessionID *string
	DeviceID  *string
	IP        string
	Meta      json.RawMessage
}

// CleanupStats reports what a Cleanup pass did.
type CleanupStats struct {
	QRExpired, QRDeleted, ChallengesDeleted, SessionsRevoked, SessionsDeleted int64
}

// Retention periods applied by Cleanup.
const (
	QRRetention             = 24 * time.Hour
	DeadSessionRetention    = 30 * 24 * time.Hour
	PendingSessionRetention = 5 * time.Minute
)

// Store is everything the HTTP layer needs. All methods take the current
// time explicitly so that behaviour is testable and consistent across
// implementations. Times are truncated to microseconds by callers.
type Store interface {
	Ping(ctx context.Context) error
	Close()

	// CreateVault atomically creates the vault and its first device.
	CreateVault(ctx context.Context, v Vault, first Device) error
	GetVault(ctx context.Context) (*Vault, error)
	// AdvanceTOTPStep records step as used; it returns false if step is not
	// greater than the last accepted step (a replay).
	AdvanceTOTPStep(ctx context.Context, step int64) (bool, error)

	GetDevice(ctx context.Context, id string) (*Device, error)
	ListDevices(ctx context.Context) ([]Device, error)
	TouchDevice(ctx context.Context, id string, now time.Time) error
	// ReplaceDevices revokes every device and every session, then registers d.
	ReplaceDevices(ctx context.Context, d Device, now time.Time) error

	PutChallenge(ctx context.Context, nonceHash []byte, deviceID string, expiresAt time.Time) error
	// TakeChallenge deletes the challenge and reports whether it existed,
	// belonged to deviceID and had not expired.
	TakeChallenge(ctx context.Context, nonceHash []byte, deviceID string, now time.Time) (bool, error)

	// CreateSession stores an active session with the given token hash.
	CreateSession(ctx context.Context, s Session, tokenHash []byte) error
	GetSessionByTokenHash(ctx context.Context, tokenHash []byte) (*Session, error)
	GetSession(ctx context.Context, id string) (*Session, error)
	TouchSession(ctx context.Context, id string, now time.Time) error
	// ListSessions returns active, non-revoked sessions, newest first.
	ListSessions(ctx context.Context) ([]Session, error)
	// RevokeSession reports whether a live session was revoked.
	RevokeSession(ctx context.Context, id string, now time.Time) (bool, error)

	CreateQR(ctx context.Context, q QRRequest) error
	GetQR(ctx context.Context, sid string) (*QRRequest, error)
	// ApproveQR atomically moves pending -> approved and creates the (not yet
	// active) web session. ErrQRExpired if now >= expires_at, ErrQRState if
	// the request is not pending.
	ApproveQR(ctx context.Context, sid string, a QRApproval, pending Session, now time.Time) error
	// RejectQR moves pending -> rejected.
	RejectQR(ctx context.Context, sid string, now time.Time) error
	// ConsumeQR atomically moves approved -> consumed, activates the session
	// with tokenHash and returns the request. It can succeed only once.
	// ErrQRExpired if the approval is older than maxAge.
	ConsumeQR(ctx context.Context, sid string, tokenHash []byte, now time.Time, maxAge time.Duration) (*QRRequest, error)

	// ListItems returns items (including tombstones) with updated_at > since,
	// ordered by updated_at then id. A nil since returns everything.
	ListItems(ctx context.Context, since *time.Time) ([]Item, error)
	// PutItem creates (expectedVersion 0) or replaces an item. On
	// ErrVersionConflict or ErrGone the current item is returned.
	PutItem(ctx context.Context, id string, ciphertext, nonce []byte, expectedVersion int64, now time.Time) (*Item, error)
	// DeleteItem turns an item into a tombstone, bumping its version.
	DeleteItem(ctx context.Context, id string, expectedVersion int64, now time.Time) (*Item, error)

	AppendAudit(ctx context.Context, e AuditEntry) error
	// ListAudit returns up to limit entries with id < beforeID (0 = newest), newest first.
	ListAudit(ctx context.Context, limit int, beforeID int64) ([]AuditEntry, error)

	Cleanup(ctx context.Context, now time.Time) (CleanupStats, error)
}
