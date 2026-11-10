package store

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// Mem is an in-memory Store. It is safe for concurrent use and mirrors the
// semantics of the Postgres implementation; the shared conformance tests run
// against both.
type Mem struct {
	mu         sync.Mutex
	vault      *Vault
	devices    map[string]*Device
	sessions   map[string]*memSession
	qr         map[string]*QRRequest
	items      map[string]*Item
	challenges map[string]memChallenge
	audit      []AuditEntry
	auditSeq   int64
}

type memSession struct {
	Session
	tokenHash []byte
}

type memChallenge struct {
	deviceID  string
	expiresAt time.Time
}

// NewMem returns an empty in-memory store.
func NewMem() *Mem {
	return &Mem{
		devices:    map[string]*Device{},
		sessions:   map[string]*memSession{},
		qr:         map[string]*QRRequest{},
		items:      map[string]*Item{},
		challenges: map[string]memChallenge{},
	}
}

func cp(b []byte) []byte { return bytes.Clone(b) }

func cpTime(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	c := *t
	return &c
}

func cpStr(s *string) *string {
	if s == nil {
		return nil
	}
	c := *s
	return &c
}

func cpJSON(j json.RawMessage) json.RawMessage {
	if len(j) == 0 {
		return json.RawMessage(`{}`)
	}
	return slices.Clone(j)
}

func cpDevice(d *Device) Device {
	c := *d
	c.Ed25519Pub = cp(d.Ed25519Pub)
	c.LastSeen, c.RevokedAt = cpTime(d.LastSeen), cpTime(d.RevokedAt)
	return c
}

func cpSession(s *memSession) Session {
	c := s.Session
	c.DeviceID, c.RevokedAt = cpStr(s.DeviceID), cpTime(s.RevokedAt)
	c.ClientInfo = cpJSON(s.ClientInfo)
	c.Active = s.tokenHash != nil
	return c
}

func cpQR(q *QRRequest) QRRequest {
	c := *q
	c.BrowserPub, c.PollTokenHash = cp(q.BrowserPub), cp(q.PollTokenHash)
	c.PhoneEphPub, c.Nonce, c.Ciphertext, c.Signature = cp(q.PhoneEphPub), cp(q.Nonce), cp(q.Ciphertext), cp(q.Signature)
	c.ClientInfo = cpJSON(q.ClientInfo)
	c.DeviceID, c.SessionID, c.ApprovedAt = cpStr(q.DeviceID), cpStr(q.SessionID), cpTime(q.ApprovedAt)
	return c
}

func cpItem(i *Item) Item {
	c := *i
	c.Ciphertext, c.Nonce, c.DeletedAt = cp(i.Ciphertext), cp(i.Nonce), cpTime(i.DeletedAt)
	return c
}

func (m *Mem) Ping(context.Context) error { return nil }
func (m *Mem) Close()                     {}

func (m *Mem) CreateVault(_ context.Context, v Vault, first Device) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.vault != nil {
		return ErrVaultExists
	}
	c := v
	c.KDFParams = cpJSON(v.KDFParams)
	m.vault = &c
	d := cpDevice(&first)
	m.devices[d.ID] = &d
	return nil
}

func (m *Mem) GetVault(context.Context) (*Vault, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.vault == nil {
		return nil, ErrNotFound
	}
	c := *m.vault
	return &c, nil
}

func (m *Mem) AdvanceTOTPStep(_ context.Context, step int64) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.vault == nil {
		return false, ErrNotFound
	}
	if step <= m.vault.TOTPLastStep {
		return false, nil
	}
	m.vault.TOTPLastStep = step
	return true, nil
}

func (m *Mem) GetDevice(_ context.Context, id string) (*Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[id]
	if !ok {
		return nil, ErrNotFound
	}
	c := cpDevice(d)
	return &c, nil
}

func (m *Mem) ListDevices(context.Context) ([]Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Device, 0, len(m.devices))
	for _, d := range m.devices {
		out = append(out, cpDevice(d))
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].CreatedAt.After(out[j].CreatedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

func (m *Mem) TouchDevice(_ context.Context, id string, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if d, ok := m.devices[id]; ok {
		d.LastSeen = &now
	}
	return nil
}

func (m *Mem) ReplaceDevices(_ context.Context, d Device, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, old := range m.devices {
		if old.RevokedAt == nil {
			old.RevokedAt = &now
		}
	}
	for _, s := range m.sessions {
		if s.RevokedAt == nil {
			s.RevokedAt = &now
		}
	}
	clear(m.challenges)
	for _, q := range m.qr {
		if q.Status == QRPending || q.Status == QRApproved {
			q.Status = QRExpired
		}
	}
	c := cpDevice(&d)
	m.devices[c.ID] = &c
	return nil
}

func (m *Mem) PutChallenge(_ context.Context, nonceHash []byte, deviceID string, expiresAt time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.challenges[hex.EncodeToString(nonceHash)] = memChallenge{deviceID, expiresAt}
	return nil
}

func (m *Mem) TakeChallenge(_ context.Context, nonceHash []byte, deviceID string, now time.Time) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := hex.EncodeToString(nonceHash)
	c, ok := m.challenges[k]
	if !ok || c.deviceID != deviceID {
		return false, nil
	}
	delete(m.challenges, k)
	return now.Before(c.expiresAt), nil
}

func (m *Mem) CreateSession(_ context.Context, s Session, tokenHash []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	ms := &memSession{Session: s, tokenHash: cp(tokenHash)}
	ms.ClientInfo = cpJSON(s.ClientInfo)
	m.sessions[s.ID] = ms
	return nil
}

func (m *Mem) GetSessionByTokenHash(_ context.Context, tokenHash []byte) (*Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, s := range m.sessions {
		if s.tokenHash != nil && bytes.Equal(s.tokenHash, tokenHash) {
			c := cpSession(s)
			return &c, nil
		}
	}
	return nil, ErrNotFound
}

func (m *Mem) GetSession(_ context.Context, id string) (*Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	if !ok {
		return nil, ErrNotFound
	}
	c := cpSession(s)
	return &c, nil
}

func (m *Mem) TouchSession(_ context.Context, id string, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s, ok := m.sessions[id]; ok && s.RevokedAt == nil {
		s.LastSeen = now
	}
	return nil
}

func (m *Mem) ListSessions(context.Context) ([]Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Session
	for _, s := range m.sessions {
		if s.RevokedAt == nil && s.tokenHash != nil {
			out = append(out, cpSession(s))
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].CreatedAt.After(out[j].CreatedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

func (m *Mem) RevokeSession(_ context.Context, id string, now time.Time) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	if !ok || s.RevokedAt != nil {
		return false, nil
	}
	s.RevokedAt = &now
	return true, nil
}

func (m *Mem) CreateQR(_ context.Context, q QRRequest) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c := cpQR(&q)
	m.qr[q.SID] = &c
	return nil
}

func (m *Mem) GetQR(_ context.Context, sid string) (*QRRequest, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	q, ok := m.qr[sid]
	if !ok {
		return nil, ErrNotFound
	}
	c := cpQR(q)
	return &c, nil
}

func (m *Mem) ApproveQR(_ context.Context, sid string, a QRApproval, pending Session, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	q, ok := m.qr[sid]
	if !ok {
		return ErrNotFound
	}
	if q.Status != QRPending {
		return ErrQRState
	}
	if !now.Before(q.ExpiresAt) {
		return ErrQRExpired
	}
	q.Status = QRApproved
	q.PhoneEphPub, q.Nonce, q.Ciphertext, q.Signature = cp(a.PhoneEphPub), cp(a.Nonce), cp(a.Ciphertext), cp(a.Signature)
	q.DeviceID, q.ApprovedAt, q.SessionID = &a.DeviceID, &now, &pending.ID
	ms := &memSession{Session: pending}
	ms.ClientInfo = cpJSON(pending.ClientInfo)
	m.sessions[pending.ID] = ms
	return nil
}

func (m *Mem) RejectQR(_ context.Context, sid string, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	q, ok := m.qr[sid]
	if !ok {
		return ErrNotFound
	}
	if q.Status != QRPending {
		return ErrQRState
	}
	q.Status = QRRejected
	return nil
}

func (m *Mem) ConsumeQR(_ context.Context, sid string, tokenHash []byte, now time.Time, maxAge time.Duration) (*QRRequest, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	q, ok := m.qr[sid]
	if !ok {
		return nil, ErrNotFound
	}
	if q.Status != QRApproved || q.SessionID == nil || q.ApprovedAt == nil {
		return nil, ErrQRState
	}
	if now.Sub(*q.ApprovedAt) > maxAge {
		return nil, ErrQRExpired
	}
	s, ok := m.sessions[*q.SessionID]
	if !ok || s.RevokedAt != nil || s.tokenHash != nil {
		return nil, ErrQRState
	}
	out := cpQR(q)
	out.Status = QRConsumed
	s.tokenHash, s.LastSeen = cp(tokenHash), now
	q.Status = QRConsumed
	// The transfer payload is single-use; drop it once delivered.
	q.PhoneEphPub, q.Nonce, q.Ciphertext, q.Signature = nil, nil, nil, nil
	return &out, nil
}

func (m *Mem) ListItems(_ context.Context, since *time.Time) ([]Item, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []Item{}
	for _, it := range m.items {
		if since == nil || it.UpdatedAt.After(*since) {
			out = append(out, cpItem(it))
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].UpdatedAt.Equal(out[j].UpdatedAt) {
			return out[i].UpdatedAt.Before(out[j].UpdatedAt)
		}
		return strings.Compare(out[i].ID, out[j].ID) < 0
	})
	return out, nil
}

func (m *Mem) PutItem(_ context.Context, id string, ciphertext, nonce []byte, expectedVersion int64, now time.Time) (*Item, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cur, ok := m.items[id]
	if !ok {
		if expectedVersion != 0 {
			return nil, ErrNotFound
		}
		it := &Item{ID: id, Ciphertext: cp(ciphertext), Nonce: cp(nonce), Version: 1, UpdatedAt: now}
		m.items[id] = it
		c := cpItem(it)
		return &c, nil
	}
	if cur.DeletedAt != nil {
		c := cpItem(cur)
		return &c, ErrGone
	}
	if cur.Version != expectedVersion {
		c := cpItem(cur)
		return &c, ErrVersionConflict
	}
	cur.Ciphertext, cur.Nonce, cur.Version, cur.UpdatedAt = cp(ciphertext), cp(nonce), cur.Version+1, now
	c := cpItem(cur)
	return &c, nil
}

func (m *Mem) DeleteItem(_ context.Context, id string, expectedVersion int64, now time.Time) (*Item, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cur, ok := m.items[id]
	if !ok {
		return nil, ErrNotFound
	}
	if cur.DeletedAt != nil {
		c := cpItem(cur)
		return &c, ErrGone
	}
	if cur.Version != expectedVersion {
		c := cpItem(cur)
		return &c, ErrVersionConflict
	}
	cur.Ciphertext, cur.Nonce, cur.Version, cur.UpdatedAt, cur.DeletedAt = nil, nil, cur.Version+1, now, &now
	c := cpItem(cur)
	return &c, nil
}

func (m *Mem) AppendAudit(_ context.Context, e AuditEntry) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.auditSeq++
	e.ID = m.auditSeq
	e.Meta = cpJSON(e.Meta)
	e.SessionID, e.DeviceID = cpStr(e.SessionID), cpStr(e.DeviceID)
	m.audit = append(m.audit, e)
	return nil
}

func (m *Mem) ListAudit(_ context.Context, limit int, beforeID int64) ([]AuditEntry, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []AuditEntry{}
	for i := len(m.audit) - 1; i >= 0 && len(out) < limit; i-- {
		if beforeID == 0 || m.audit[i].ID < beforeID {
			e := m.audit[i]
			e.Meta = cpJSON(e.Meta)
			out = append(out, e)
		}
	}
	return out, nil
}

func (m *Mem) Cleanup(_ context.Context, now time.Time) (CleanupStats, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var st CleanupStats
	for sid, q := range m.qr {
		if q.Status == QRPending && !now.Before(q.ExpiresAt) {
			q.Status = QRExpired
			st.QRExpired++
		}
		if now.Sub(q.CreatedAt) > QRRetention {
			delete(m.qr, sid)
			st.QRDeleted++
		}
	}
	for k, c := range m.challenges {
		if !now.Before(c.expiresAt) {
			delete(m.challenges, k)
			st.ChallengesDeleted++
		}
	}
	for id, s := range m.sessions {
		switch {
		case s.tokenHash == nil && now.Sub(s.CreatedAt) > PendingSessionRetention:
			delete(m.sessions, id)
			st.SessionsDeleted++
		case s.RevokedAt != nil && now.Sub(*s.RevokedAt) > DeadSessionRetention:
			delete(m.sessions, id)
			st.SessionsDeleted++
		case s.RevokedAt == nil && s.tokenHash != nil && now.Sub(s.LastSeen) > time.Duration(s.IdleTimeoutSeconds)*time.Second:
			s.RevokedAt = &now
			st.SessionsRevoked++
		}
	}
	return st, nil
}

var _ Store = (*Mem)(nil)
