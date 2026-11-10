// Command leopard-api serves the Leopard HTTP API.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/leopard-vault/leopard/backend/internal/config"
	"github.com/leopard-vault/leopard/backend/internal/httpapi"
	"github.com/leopard-vault/leopard/backend/internal/migrations"
	"github.com/leopard-vault/leopard/backend/internal/store"
)

func main() {
	// Cloud Logging reads "severity" and "message" from JSON lines on stdout.
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			switch a.Key {
			case slog.LevelKey:
				a.Key = "severity"
			case slog.MessageKey:
				a.Key = "message"
			}
			return a
		},
	}))
	if err := run(log); err != nil {
		log.Error("fatal", "err", err.Error())
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := config.FromEnv(os.Getenv)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var st store.Store
	if cfg.DevMemStore {
		log.Warn("LEOPARD_DEV_MEMSTORE=1: using an in-memory store; all data is lost on exit")
		st = store.NewMem()
	} else {
		startCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		pg, err := store.OpenPG(startCtx, cfg.DatabaseURL)
		if err != nil {
			cancel()
			return err
		}
		applied, err := migrations.Up(startCtx, pg.Pool())
		cancel()
		if err != nil {
			pg.Close()
			return err
		}
		if len(applied) > 0 {
			log.Info("migrations applied", "names", applied)
		}
		st = pg
	}
	defer st.Close()

	if len(cfg.WebOrigins) == 0 {
		log.Warn("LEOPARD_WEB_ORIGIN is empty: every browser origin will be refused")
	}
	api, err := httpapi.New(httpapi.Options{
		Store: st, ServerKey: cfg.ServerKey, WebOrigins: cfg.WebOrigins,
		TrustedProxyHops: cfg.TrustedProxyHops, SetupToken: cfg.SetupToken, Logger: log,
	})
	if err != nil {
		return err
	}
	go api.RunCleanup(ctx, httpapi.CleanupInterval)

	srv := &http.Server{
		Addr:              net.JoinHostPort("", cfg.Port),
		Handler:           api,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	log.Info("listening", "port", cfg.Port, "trusted_proxy_hops", cfg.TrustedProxyHops, "web_origins", cfg.WebOrigins)

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
