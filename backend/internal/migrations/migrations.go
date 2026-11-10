// Package migrations embeds the SQL schema and applies it in order.
//
// Files in sql/ are named NNNN_description.sql and are applied once each, in
// lexical order, inside a transaction, under a Postgres advisory lock so that
// two instances starting together do not race.
package migrations

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"sort"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed sql/*.sql
var files embed.FS

// advisoryLockKey is an arbitrary constant ("leopard" in ASCII, truncated).
const advisoryLockKey int64 = 0x6c656f70617264

// Names returns the embedded migration file names in apply order.
func Names() ([]string, error) {
	entries, err := fs.ReadDir(files, "sql")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names, nil
}

// Up applies all pending migrations and returns the names it applied.
func Up(ctx context.Context, pool *pgxpool.Pool) ([]string, error) {
	names, err := Names()
	if err != nil {
		return nil, err
	}
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, advisoryLockKey); err != nil {
		return nil, fmt.Errorf("migrations: lock: %w", err)
	}
	defer conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock($1)`, advisoryLockKey) //nolint:errcheck

	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return nil, fmt.Errorf("migrations: bookkeeping table: %w", err)
	}

	var applied []string
	for _, name := range names {
		var done bool
		if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE name = $1)`, name).Scan(&done); err != nil {
			return applied, err
		}
		if done {
			continue
		}
		body, err := files.ReadFile("sql/" + name)
		if err != nil {
			return applied, err
		}
		err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			// Simple protocol so a file may contain several statements.
			if _, err := tx.Exec(ctx, string(body), pgx.QueryExecModeSimpleProtocol); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO schema_migrations (name) VALUES ($1)`, name)
			return err
		})
		if err != nil {
			return applied, fmt.Errorf("migrations: %s: %w", name, err)
		}
		applied = append(applied, name)
	}
	return applied, nil
}
