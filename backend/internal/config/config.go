// Package config reads the service configuration from the environment.
package config

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
)

// Config is the validated runtime configuration.
type Config struct {
	DatabaseURL string
	Port        string
	// WebOrigins is the CORS allowlist (scheme://host[:port], no path).
	WebOrigins []string
	// ServerKey is the 32-byte key that encrypts the TOTP secret at rest.
	ServerKey []byte
	// TrustedProxyHops is how many reverse proxies in front of the service
	// append to X-Forwarded-For. 0 means the header is ignored.
	TrustedProxyHops int
	// SetupToken, if set, must accompany POST /v1/setup.
	SetupToken string
	// DevMemStore runs without Postgres, keeping everything in memory.
	DevMemStore bool
}

// FromEnv builds a Config using getenv (normally os.Getenv).
func FromEnv(getenv func(string) string) (Config, error) {
	c := Config{
		DatabaseURL: getenv("DATABASE_URL"),
		Port:        getenv("PORT"),
		SetupToken:  getenv("LEOPARD_SETUP_TOKEN"),
		DevMemStore: getenv("LEOPARD_DEV_MEMSTORE") == "1",
	}
	if c.Port == "" {
		c.Port = "8080"
	}
	if n, err := strconv.Atoi(c.Port); err != nil || n < 1 || n > 65535 {
		return c, errors.New("config: PORT must be a TCP port number")
	}
	if c.DatabaseURL == "" && !c.DevMemStore {
		return c, errors.New("config: DATABASE_URL is required (or set LEOPARD_DEV_MEMSTORE=1 for a throwaway in-memory store)")
	}
	if c.SetupToken != "" && len(c.SetupToken) < 16 {
		return c, errors.New("config: LEOPARD_SETUP_TOKEN must be at least 16 characters")
	}

	key, err := parseKey(getenv("LEOPARD_SERVER_KEY"))
	if err != nil {
		return c, err
	}
	c.ServerKey = key

	for _, o := range strings.Split(getenv("LEOPARD_WEB_ORIGIN"), ",") {
		o = strings.TrimSpace(o)
		if o == "" {
			continue
		}
		u, err := url.Parse(o)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
			return c, fmt.Errorf("config: LEOPARD_WEB_ORIGIN entry %q must look like https://host[:port]", o)
		}
		c.WebOrigins = append(c.WebOrigins, u.Scheme+"://"+u.Host)
	}

	switch tp := getenv("LEOPARD_TRUST_PROXY"); tp {
	case "", "0":
	default:
		n, err := strconv.Atoi(tp)
		if err != nil || n < 1 || n > 5 {
			return c, errors.New("config: LEOPARD_TRUST_PROXY must be 0, 1 (Cloud Run) or the number of trusted proxy hops")
		}
		c.TrustedProxyHops = n
	}
	return c, nil
}

// parseKey accepts 32 bytes as base64 (standard or URL alphabet, padded or not).
func parseKey(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, errors.New("config: LEOPARD_SERVER_KEY is required (32 random bytes, base64; e.g. `openssl rand -base64 32`)")
	}
	s = strings.TrimRight(s, "=")
	s = strings.NewReplacer("+", "-", "/", "_").Replace(s)
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil || len(b) != 32 {
		return nil, errors.New("config: LEOPARD_SERVER_KEY must be exactly 32 bytes of base64")
	}
	return b, nil
}
