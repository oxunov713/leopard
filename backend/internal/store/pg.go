package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PG is the Postgres implementation of Store.
type PG struct {
	pool *pgxpool.Pool
}

// OpenPG connects to Postgres. The pool is kept small: this is a single-user
// service and serverless Postgres plans cap connections.
func OpenPG(ctx context.Context, databaseURL string) (*PG, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		// Do not wrap err: pgx includes the connection string in some parse errors.
		return nil, errors.New("store: invalid DATABASE_URL")
	}
	if cfg.MaxConns > 5 {
		cfg.MaxConns = 5
	}
	cfg.MaxConnIdleTime = 2 * time.Minute
	cfg.MaxConnLifetime = 30 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("store: connect: %w", err)
	}
	return &PG{pool: pool}, nil
}

// Pool exposes the pool for migrations.
func (p *PG) Pool() *pgxpool.Pool { return p.pool }

func (p *PG) Ping(ctx context.Context) error { return p.pool.Ping(ctx) }
func (p *PG) Close()                         { p.pool.Close() }

func utc(t time.Time) time.Time { return t.UTC() }

func utcPtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	u := t.UTC()
	return &u
}

func notFound(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

func (p *PG) CreateVault(ctx context.Context, v Vault, first Device) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			INSERT INTO vault (id, kdf_params, salt, wrapped_vk_master, wrapped_vk_recovery,
				master_auth_verifier, recovery_auth_verifier, totp_secret_enc, totp_last_step, created_at)
			VALUES (1, $1, $2, $3, $4, $5, $6, $7, $8, $9)
			ON CONFLICT (id) DO NOTHING`,
			[]byte(v.KDFParams), v.Salt, v.WrappedVKMaster, v.WrappedVKRecovery,
			v.MasterAuthVerifier, v.RecoveryAuthVerifier, v.TOTPSecretEnc, v.TOTPLastStep, v.CreatedAt)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrVaultExists
		}
		return insertDevice(ctx, tx, first)
	})
}

func insertDevice(ctx context.Context, tx pgx.Tx, d Device) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO devices (id, label, ed25519_pub, created_at, last_seen, revoked_at)
		VALUES ($1, $2, $3, $4, $5, $6)`,
		d.ID, d.Label, d.Ed25519Pub, d.CreatedAt, d.LastSeen, d.RevokedAt)
	return err
}

func (p *PG) GetVault(ctx context.Context) (*Vault, error) {
	var v Vault
	var params []byte
	err := p.pool.QueryRow(ctx, `
		SELECT kdf_params, salt, wrapped_vk_master, wrapped_vk_recovery, master_auth_verifier,
			recovery_auth_verifier, totp_secret_enc, totp_last_step, created_at
		FROM vault WHERE id = 1`).Scan(&params, &v.Salt, &v.WrappedVKMaster, &v.WrappedVKRecovery,
		&v.MasterAuthVerifier, &v.RecoveryAuthVerifier, &v.TOTPSecretEnc, &v.TOTPLastStep, &v.CreatedAt)
	if err != nil {
		return nil, notFound(err)
	}
	v.KDFParams, v.CreatedAt = params, utc(v.CreatedAt)
	return &v, nil
}

func (p *PG) AdvanceTOTPStep(ctx context.Context, step int64) (bool, error) {
	tag, err := p.pool.Exec(ctx, `UPDATE vault SET totp_last_step = $1 WHERE id = 1 AND totp_last_step < $1`, step)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

const deviceCols = `id::text, label, ed25519_pub, created_at, last_seen, revoked_at`

func scanDevice(row pgx.Row) (*Device, error) {
	var d Device
	if err := row.Scan(&d.ID, &d.Label, &d.Ed25519Pub, &d.CreatedAt, &d.LastSeen, &d.RevokedAt); err != nil {
		return nil, notFound(err)
	}
	d.CreatedAt, d.LastSeen, d.RevokedAt = utc(d.CreatedAt), utcPtr(d.LastSeen), utcPtr(d.RevokedAt)
	return &d, nil
}

func (p *PG) GetDevice(ctx context.Context, id string) (*Device, error) {
	return scanDevice(p.pool.QueryRow(ctx, `SELECT `+deviceCols+` FROM devices WHERE id = $1`, id))
}

func (p *PG) ListDevices(ctx context.Context) ([]Device, error) {
	rows, err := p.pool.Query(ctx, `SELECT `+deviceCols+` FROM devices ORDER BY created_at DESC, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Device{}
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}

func (p *PG) TouchDevice(ctx context.Context, id string, now time.Time) error {
	_, err := p.pool.Exec(ctx, `UPDATE devices SET last_seen = $2 WHERE id = $1`, id, now)
	return err
}

func (p *PG) ReplaceDevices(ctx context.Context, d Device, now time.Time) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		stmts := []string{
			`UPDATE devices SET revoked_at = $1 WHERE revoked_at IS NULL`,
			`UPDATE sessions SET revoked_at = $1 WHERE revoked_at IS NULL`,
			`UPDATE qr_requests SET status = 'expired' WHERE status IN ('pending', 'approved') AND created_at <= $1`,
			// Every statement takes the single argument $1, hence the tautology: delete all challenges.
			`DELETE FROM device_challenges WHERE expires_at > $1 OR expires_at <= $1`,
		}
		for _, s := range stmts {
			if _, err := tx.Exec(ctx, s, now); err != nil {
				return err
			}
		}
		return insertDevice(ctx, tx, d)
	})
}

func (p *PG) PutChallenge(ctx context.Context, nonceHash []byte, deviceID string, expiresAt time.Time) error {
	_, err := p.pool.Exec(ctx, `
		INSERT INTO device_challenges (nonce_hash, device_id, expires_at) VALUES ($1, $2, $3)
		ON CONFLICT (nonce_hash) DO UPDATE SET device_id = EXCLUDED.device_id, expires_at = EXCLUDED.expires_at`,
		nonceHash, deviceID, expiresAt)
	return err
}

func (p *PG) TakeChallenge(ctx context.Context, nonceHash []byte, deviceID string, now time.Time) (bool, error) {
	var expiresAt time.Time
	err := p.pool.QueryRow(ctx, `
		DELETE FROM device_challenges WHERE nonce_hash = $1 AND device_id = $2 RETURNING expires_at`,
		nonceHash, deviceID).Scan(&expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return now.Before(expiresAt), nil
}

// execer is satisfied by both *pgxpool.Pool and pgx.Tx.
type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func insertSession(ctx context.Context, db execer, s Session, tokenHash []byte) error {
	_, err := db.Exec(ctx, `
		INSERT INTO sessions (id, token_hash, kind, device_id, client_info, ip, created_at, last_seen, idle_timeout_seconds, revoked_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
		s.ID, tokenHash, s.Kind, s.DeviceID, jsonOrEmpty(s.ClientInfo), s.IP, s.CreatedAt, s.LastSeen, s.IdleTimeoutSeconds, s.RevokedAt)
	return err
}

func (p *PG) CreateSession(ctx context.Context, s Session, tokenHash []byte) error {
	return insertSession(ctx, p.pool, s, tokenHash)
}

const sessionCols = `id::text, kind, device_id::text, client_info, ip, created_at, last_seen, idle_timeout_seconds, revoked_at, token_hash IS NOT NULL`

func scanSession(row pgx.Row) (*Session, error) {
	var s Session
	var info []byte
	if err := row.Scan(&s.ID, &s.Kind, &s.DeviceID, &info, &s.IP, &s.CreatedAt, &s.LastSeen,
		&s.IdleTimeoutSeconds, &s.RevokedAt, &s.Active); err != nil {
		return nil, notFound(err)
	}
	s.ClientInfo = info
	s.CreatedAt, s.LastSeen, s.RevokedAt = utc(s.CreatedAt), utc(s.LastSeen), utcPtr(s.RevokedAt)
	return &s, nil
}

func (p *PG) GetSessionByTokenHash(ctx context.Context, tokenHash []byte) (*Session, error) {
	return scanSession(p.pool.QueryRow(ctx, `SELECT `+sessionCols+` FROM sessions WHERE token_hash = $1`, tokenHash))
}

func (p *PG) GetSession(ctx context.Context, id string) (*Session, error) {
	return scanSession(p.pool.QueryRow(ctx, `SELECT `+sessionCols+` FROM sessions WHERE id = $1`, id))
}

func (p *PG) TouchSession(ctx context.Context, id string, now time.Time) error {
	_, err := p.pool.Exec(ctx, `UPDATE sessions SET last_seen = $2 WHERE id = $1 AND revoked_at IS NULL`, id, now)
	return err
}

func (p *PG) ListSessions(ctx context.Context) ([]Session, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT `+sessionCols+` FROM sessions
		WHERE revoked_at IS NULL AND token_hash IS NOT NULL
		ORDER BY created_at DESC, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Session
	for rows.Next() {
		s, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

func (p *PG) RevokeSession(ctx context.Context, id string, now time.Time) (bool, error) {
	tag, err := p.pool.Exec(ctx, `UPDATE sessions SET revoked_at = $2 WHERE id = $1 AND revoked_at IS NULL`, id, now)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

func (p *PG) CreateQR(ctx context.Context, q QRRequest) error {
	_, err := p.pool.Exec(ctx, `
		INSERT INTO qr_requests (sid, browser_pub, poll_token_hash, client_info, ip, created_at, expires_at, status)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		q.SID, q.BrowserPub, q.PollTokenHash, jsonOrEmpty(q.ClientInfo), q.IP, q.CreatedAt, q.ExpiresAt, q.Status)
	return err
}

func jsonOrEmpty(b []byte) []byte {
	if len(b) == 0 {
		return []byte(`{}`)
	}
	return b
}

const qrCols = `sid, browser_pub, poll_token_hash, client_info, ip, created_at, expires_at, status,
	phone_eph_pub, nonce, ciphertext, signature, device_id::text, approved_at, session_id::text`

func scanQR(row pgx.Row) (*QRRequest, error) {
	var q QRRequest
	var info []byte
	if err := row.Scan(&q.SID, &q.BrowserPub, &q.PollTokenHash, &info, &q.IP, &q.CreatedAt, &q.ExpiresAt, &q.Status,
		&q.PhoneEphPub, &q.Nonce, &q.Ciphertext, &q.Signature, &q.DeviceID, &q.ApprovedAt, &q.SessionID); err != nil {
		return nil, notFound(err)
	}
	q.ClientInfo = info
	q.CreatedAt, q.ExpiresAt, q.ApprovedAt = utc(q.CreatedAt), utc(q.ExpiresAt), utcPtr(q.ApprovedAt)
	return &q, nil
}

func (p *PG) GetQR(ctx context.Context, sid string) (*QRRequest, error) {
	return scanQR(p.pool.QueryRow(ctx, `SELECT `+qrCols+` FROM qr_requests WHERE sid = $1`, sid))
}

func (p *PG) ApproveQR(ctx context.Context, sid string, a QRApproval, pending Session, now time.Time) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var status string
		var expiresAt time.Time
		err := tx.QueryRow(ctx, `SELECT status, expires_at FROM qr_requests WHERE sid = $1 FOR UPDATE`, sid).Scan(&status, &expiresAt)
		if err != nil {
			return notFound(err)
		}
		if status != QRPending {
			return ErrQRState
		}
		if !now.Before(expiresAt) {
			return ErrQRExpired
		}
		if err := insertSession(ctx, tx, pending, nil); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `
			UPDATE qr_requests SET status = 'approved', phone_eph_pub = $2, nonce = $3, ciphertext = $4,
				signature = $5, device_id = $6, approved_at = $7, session_id = $8
			WHERE sid = $1`,
			sid, a.PhoneEphPub, a.Nonce, a.Ciphertext, a.Signature, a.DeviceID, now, pending.ID)
		return err
	})
}

func (p *PG) RejectQR(ctx context.Context, sid string, now time.Time) error {
	tag, err := p.pool.Exec(ctx, `UPDATE qr_requests SET status = 'rejected' WHERE sid = $1 AND status = 'pending'`, sid)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 1 {
		return nil
	}
	var exists bool
	if err := p.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM qr_requests WHERE sid = $1)`, sid).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return ErrNotFound
	}
	return ErrQRState
}

func (p *PG) ConsumeQR(ctx context.Context, sid string, tokenHash []byte, now time.Time, maxAge time.Duration) (*QRRequest, error) {
	var out *QRRequest
	err := pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		q, err := scanQR(tx.QueryRow(ctx, `SELECT `+qrCols+` FROM qr_requests WHERE sid = $1 FOR UPDATE`, sid))
		if err != nil {
			return err
		}
		if q.Status != QRApproved || q.SessionID == nil || q.ApprovedAt == nil {
			return ErrQRState
		}
		if now.Sub(*q.ApprovedAt) > maxAge {
			return ErrQRExpired
		}
		tag, err := tx.Exec(ctx, `
			UPDATE sessions SET token_hash = $2, last_seen = $3
			WHERE id = $1 AND token_hash IS NULL AND revoked_at IS NULL`, *q.SessionID, tokenHash, now)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return ErrQRState
		}
		// The transfer payload is single-use; drop it once delivered.
		if _, err := tx.Exec(ctx, `
			UPDATE qr_requests SET status = 'consumed', phone_eph_pub = NULL, nonce = NULL, ciphertext = NULL, signature = NULL
			WHERE sid = $1`, sid); err != nil {
			return err
		}
		q.Status = QRConsumed
		out = q
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

const itemCols = `id::text, ciphertext, nonce, version, updated_at, deleted_at`

func scanItem(row pgx.Row) (*Item, error) {
	var it Item
	if err := row.Scan(&it.ID, &it.Ciphertext, &it.Nonce, &it.Version, &it.UpdatedAt, &it.DeletedAt); err != nil {
		return nil, notFound(err)
	}
	it.UpdatedAt, it.DeletedAt = utc(it.UpdatedAt), utcPtr(it.DeletedAt)
	return &it, nil
}

func (p *PG) ListItems(ctx context.Context, since *time.Time) ([]Item, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT `+itemCols+` FROM items
		WHERE $1::timestamptz IS NULL OR updated_at > $1
		ORDER BY updated_at, id`, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Item{}
	for rows.Next() {
		it, err := scanItem(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *it)
	}
	return out, rows.Err()
}

// currentItem explains why a conditional write matched no row.
func (p *PG) currentItem(ctx context.Context, id string) (*Item, error) {
	cur, err := scanItem(p.pool.QueryRow(ctx, `SELECT `+itemCols+` FROM items WHERE id = $1`, id))
	if err != nil {
		return nil, err
	}
	if cur.DeletedAt != nil {
		return cur, ErrGone
	}
	return cur, ErrVersionConflict
}

func (p *PG) PutItem(ctx context.Context, id string, ciphertext, nonce []byte, expectedVersion int64, now time.Time) (*Item, error) {
	var row pgx.Row
	if expectedVersion == 0 {
		row = p.pool.QueryRow(ctx, `
			INSERT INTO items (id, ciphertext, nonce, version, updated_at) VALUES ($1, $2, $3, 1, $4)
			ON CONFLICT (id) DO NOTHING RETURNING `+itemCols, id, ciphertext, nonce, now)
	} else {
		row = p.pool.QueryRow(ctx, `
			UPDATE items SET ciphertext = $2, nonce = $3, version = version + 1, updated_at = $4
			WHERE id = $1 AND version = $5 AND deleted_at IS NULL RETURNING `+itemCols,
			id, ciphertext, nonce, now, expectedVersion)
	}
	it, err := scanItem(row)
	if errors.Is(err, ErrNotFound) {
		return p.currentItem(ctx, id)
	}
	return it, err
}

func (p *PG) DeleteItem(ctx context.Context, id string, expectedVersion int64, now time.Time) (*Item, error) {
	it, err := scanItem(p.pool.QueryRow(ctx, `
		UPDATE items SET ciphertext = NULL, nonce = NULL, version = version + 1, updated_at = $2, deleted_at = $2
		WHERE id = $1 AND version = $3 AND deleted_at IS NULL RETURNING `+itemCols, id, now, expectedVersion))
	if errors.Is(err, ErrNotFound) {
		return p.currentItem(ctx, id)
	}
	return it, err
}

func (p *PG) AppendAudit(ctx context.Context, e AuditEntry) error {
	_, err := p.pool.Exec(ctx, `
		INSERT INTO audit_log (ts, event, session_id, device_id, ip, meta) VALUES ($1, $2, $3, $4, $5, $6)`,
		e.TS, e.Event, e.SessionID, e.DeviceID, e.IP, jsonOrEmpty(e.Meta))
	return err
}

func (p *PG) ListAudit(ctx context.Context, limit int, beforeID int64) ([]AuditEntry, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT id, ts, event, session_id::text, device_id::text, ip, meta FROM audit_log
		WHERE $2::bigint = 0 OR id < $2
		ORDER BY id DESC LIMIT $1`, limit, beforeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AuditEntry{}
	for rows.Next() {
		var e AuditEntry
		var meta []byte
		if err := rows.Scan(&e.ID, &e.TS, &e.Event, &e.SessionID, &e.DeviceID, &e.IP, &meta); err != nil {
			return nil, err
		}
		e.TS, e.Meta = utc(e.TS), meta
		out = append(out, e)
	}
	return out, rows.Err()
}

func (p *PG) Cleanup(ctx context.Context, now time.Time) (CleanupStats, error) {
	var st CleanupStats
	steps := []struct {
		n    *int64
		sql  string
		args []any
	}{
		{&st.QRExpired, `UPDATE qr_requests SET status = 'expired' WHERE status = 'pending' AND expires_at <= $1`, []any{now}},
		{&st.QRDeleted, `DELETE FROM qr_requests WHERE created_at < $1`, []any{now.Add(-QRRetention)}},
		{&st.ChallengesDeleted, `DELETE FROM device_challenges WHERE expires_at <= $1`, []any{now}},
		{&st.SessionsDeleted, `DELETE FROM sessions WHERE (token_hash IS NULL AND created_at < $1) OR (revoked_at IS NOT NULL AND revoked_at < $2)`,
			[]any{now.Add(-PendingSessionRetention), now.Add(-DeadSessionRetention)}},
		{&st.SessionsRevoked, `UPDATE sessions SET revoked_at = $1
			WHERE revoked_at IS NULL AND token_hash IS NOT NULL
			  AND last_seen + make_interval(secs => idle_timeout_seconds) < $1`, []any{now}},
	}
	for _, s := range steps {
		tag, err := p.pool.Exec(ctx, s.sql, s.args...)
		if err != nil {
			return st, err
		}
		*s.n += tag.RowsAffected()
	}
	return st, nil
}

var _ Store = (*PG)(nil)
