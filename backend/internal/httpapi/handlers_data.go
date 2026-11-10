package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	lcrypto "github.com/leopard-vault/leopard/backend/internal/crypto"
	"github.com/leopard-vault/leopard/backend/internal/store"
)

// ---- items ----

type itemJSON struct {
	ID         string     `json:"id"`
	Version    int64      `json:"version"`
	UpdatedAt  time.Time  `json:"updated_at"`
	Deleted    bool       `json:"deleted"`
	DeletedAt  *time.Time `json:"deleted_at,omitempty"`
	Ciphertext string     `json:"ciphertext,omitempty"`
	Nonce      string     `json:"nonce,omitempty"`
}

func toItemJSON(it *store.Item) itemJSON {
	j := itemJSON{ID: it.ID, Version: it.Version, UpdatedAt: it.UpdatedAt, Deleted: it.DeletedAt != nil, DeletedAt: it.DeletedAt}
	if it.DeletedAt == nil {
		j.Ciphertext, j.Nonce = lcrypto.B64(it.Ciphertext), lcrypto.B64(it.Nonce)
	}
	return j
}

// itemMeta is the body for conflict answers: enough to resync, no ciphertext.
func itemMeta(it *store.Item) map[string]any {
	return map[string]any{"id": it.ID, "version": it.Version, "updated_at": it.UpdatedAt, "deleted": it.DeletedAt != nil}
}

func (s *Server) handleItemsList(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	var since *time.Time
	if v := r.URL.Query().Get("since"); v != "" {
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil {
			badRequest(w, "since must be an RFC 3339 timestamp")
			return
		}
		since = &t
	}
	// Taken before the query so a client that stores it as its next cursor
	// can never skip a concurrent write.
	serverTime := s.now()
	items, err := s.st.ListItems(r.Context(), since)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	out := make([]itemJSON, 0, len(items))
	for i := range items {
		out = append(out, toItemJSON(&items[i]))
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out, "server_time": serverTime})
}

type itemPutRequest struct {
	Ciphertext      string `json:"ciphertext"`
	Nonce           string `json:"nonce"`
	ExpectedVersion *int64 `json:"expected_version"`
}

func itemID(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := r.PathValue("id")
	if !lcrypto.IsCanonicalUUID(id) {
		badRequest(w, "item id must be a lower-case UUID")
		return "", false
	}
	return id, true
}

// writeItemError maps optimistic-concurrency outcomes to HTTP.
func (s *Server) writeItemError(w http.ResponseWriter, r *http.Request, cur *store.Item, err error) {
	switch {
	case errors.Is(err, store.ErrVersionConflict):
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":   map[string]string{"code": "version_conflict", "message": "expected_version does not match the stored version"},
			"current": itemMeta(cur),
		})
	case errors.Is(err, store.ErrGone):
		writeJSON(w, http.StatusGone, map[string]any{
			"error":   map[string]string{"code": "item_deleted", "message": "the item has been deleted"},
			"current": itemMeta(cur),
		})
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "item_not_found", "no such item")
	default:
		s.internal(w, r, err)
	}
}

// handleItemPut creates (expected_version 0) or replaces an item. The stored
// version becomes expected_version + 1, and that is the version the client
// must have bound into the AEAD associated data.
func (s *Server) handleItemPut(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	id, ok := itemID(w, r)
	if !ok {
		return
	}
	var req itemPutRequest
	if !readJSON(w, r, &req) {
		return
	}
	if req.ExpectedVersion == nil || *req.ExpectedVersion < 0 {
		badRequest(w, "expected_version is required (0 to create)")
		return
	}
	nonce, ok := b64field(w, "nonce", req.Nonce, lcrypto.NonceSize)
	if !ok {
		return
	}
	ct, ok := b64field(w, "ciphertext", req.Ciphertext, -1)
	if !ok {
		return
	}
	if len(ct) <= lcrypto.TagSize || len(ct) > MaxItemCiphertext {
		badRequest(w, "ciphertext must be between 17 bytes and 256 KiB")
		return
	}
	it, err := s.st.PutItem(r.Context(), id, ct, nonce, *req.ExpectedVersion, s.now())
	if err != nil {
		s.writeItemError(w, r, it, err)
		return
	}
	status := http.StatusOK
	if it.Version == 1 {
		status = http.StatusCreated
	}
	writeJSON(w, status, itemMeta(it))
}

type itemDeleteRequest struct {
	ExpectedVersion *int64 `json:"expected_version"`
}

// handleItemDelete replaces the item with a tombstone so other clients learn
// about the deletion on their next sync.
func (s *Server) handleItemDelete(w http.ResponseWriter, r *http.Request, sess *store.Session) {
	id, ok := itemID(w, r)
	if !ok {
		return
	}
	var req itemDeleteRequest
	if !readJSON(w, r, &req) {
		return
	}
	if req.ExpectedVersion == nil || *req.ExpectedVersion < 1 {
		badRequest(w, "expected_version is required")
		return
	}
	it, err := s.st.DeleteItem(r.Context(), id, *req.ExpectedVersion, s.now())
	if err != nil {
		s.writeItemError(w, r, it, err)
		return
	}
	s.audit(r, "item_deleted", &sess.ID, sess.DeviceID, map[string]any{"item_id": id})
	writeJSON(w, http.StatusOK, itemMeta(it))
}

// ---- sessions ----

func sessionExpiry(sess *store.Session) time.Time {
	exp := sess.LastSeen.Add(time.Duration(sess.IdleTimeoutSeconds) * time.Second)
	if sess.Kind == store.KindWeb {
		if hard := sess.CreatedAt.Add(WebMaxLifetime); hard.Before(exp) {
			return hard
		}
	}
	return exp
}

// handleHeartbeat is how the web app reports user activity. Authentication
// has already failed with 401 if the session was revoked or went idle.
func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request, sess *store.Session) {
	now := s.now()
	if err := s.st.TouchSession(r.Context(), sess.ID, now); err != nil {
		s.internal(w, r, err)
		return
	}
	sess.LastSeen = now
	writeJSON(w, http.StatusOK, map[string]any{
		"session_id":           sess.ID,
		"kind":                 sess.Kind,
		"idle_timeout_seconds": sess.IdleTimeoutSeconds,
		"expires_at":           sessionExpiry(sess),
		"server_time":          now,
	})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, sess *store.Session) {
	if _, err := s.st.RevokeSession(r.Context(), sess.ID, s.now()); err != nil {
		s.internal(w, r, err)
		return
	}
	s.audit(r, "logout", &sess.ID, sess.DeviceID, nil)
	writeJSON(w, http.StatusOK, map[string]any{"status": "logged_out"})
}

func (s *Server) handleSessionsList(w http.ResponseWriter, r *http.Request, sess *store.Session) {
	list, err := s.st.ListSessions(r.Context())
	if err != nil {
		s.internal(w, r, err)
		return
	}
	now := s.now()
	out := []map[string]any{}
	for i := range list {
		x := &list[i]
		exp := sessionExpiry(x)
		if !now.Before(exp) {
			continue // dead, waiting for the cleanup job
		}
		out = append(out, map[string]any{
			"id": x.ID, "kind": x.Kind, "device_id": x.DeviceID, "client_info": x.ClientInfo, "ip": x.IP,
			"created_at": x.CreatedAt, "last_seen": x.LastSeen, "idle_timeout_seconds": x.IdleTimeoutSeconds,
			"expires_at": exp, "current": x.ID == sess.ID,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": out, "server_time": now})
}

func (s *Server) handleSessionRevoke(w http.ResponseWriter, r *http.Request, sess *store.Session) {
	id := r.PathValue("id")
	if !lcrypto.IsCanonicalUUID(id) {
		badRequest(w, "session id must be a lower-case UUID")
		return
	}
	ok, err := s.st.RevokeSession(r.Context(), id, s.now())
	if err != nil {
		s.internal(w, r, err)
		return
	}
	if !ok {
		writeError(w, http.StatusNotFound, "session_not_found", "no such active session")
		return
	}
	s.audit(r, "session_revoked", &sess.ID, sess.DeviceID, map[string]any{"revoked_session_id": id})
	writeJSON(w, http.StatusOK, map[string]any{"status": "revoked", "id": id})
}

// ---- audit ----

func (s *Server) handleAudit(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	limit, before := 100, int64(0)
	q := r.URL.Query()
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 500 {
			badRequest(w, "limit must be between 1 and 500")
			return
		}
		limit = n
	}
	if v := q.Get("before"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 1 {
			badRequest(w, "before must be a positive audit entry id")
			return
		}
		before = n
	}
	entries, err := s.st.ListAudit(r.Context(), limit, before)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	out := make([]map[string]any, 0, len(entries))
	for _, e := range entries {
		meta := e.Meta
		if len(meta) == 0 {
			meta = json.RawMessage(`{}`)
		}
		out = append(out, map[string]any{
			"id": e.ID, "ts": e.TS, "event": e.Event, "session_id": e.SessionID, "device_id": e.DeviceID, "ip": e.IP, "meta": meta,
		})
	}
	var next any
	if len(entries) == limit {
		next = entries[len(entries)-1].ID
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": out, "next_before": next})
}
