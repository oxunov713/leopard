package config

import (
	"encoding/base64"
	"strings"
	"testing"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

var key = base64.StdEncoding.EncodeToString(make([]byte, 32))

func TestDefaultsAndParsing(t *testing.T) {
	c, err := FromEnv(env(map[string]string{
		"DATABASE_URL":        "postgres://u:p@h/db?sslmode=require",
		"LEOPARD_SERVER_KEY":  key,
		"LEOPARD_WEB_ORIGIN":  "https://leopard.example, http://localhost:5173",
		"LEOPARD_TRUST_PROXY": "1",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if c.Port != "8080" || len(c.ServerKey) != 32 || c.TrustedProxyHops != 1 ||
		len(c.WebOrigins) != 2 || c.WebOrigins[0] != "https://leopard.example" || c.WebOrigins[1] != "http://localhost:5173" {
		t.Fatalf("%+v", c)
	}
}

func TestRejectsBadConfig(t *testing.T) {
	base := func() map[string]string {
		return map[string]string{"DATABASE_URL": "postgres://h/db", "LEOPARD_SERVER_KEY": key}
	}
	cases := map[string]func(m map[string]string){
		"missing db":      func(m map[string]string) { delete(m, "DATABASE_URL") },
		"missing key":     func(m map[string]string) { delete(m, "LEOPARD_SERVER_KEY") },
		"short key":       func(m map[string]string) { m["LEOPARD_SERVER_KEY"] = "c2hvcnQ" },
		"bad port":        func(m map[string]string) { m["PORT"] = "http" },
		"origin path":     func(m map[string]string) { m["LEOPARD_WEB_ORIGIN"] = "https://a.example/app" },
		"origin wildcard": func(m map[string]string) { m["LEOPARD_WEB_ORIGIN"] = "*" },
		"bad proxy":       func(m map[string]string) { m["LEOPARD_TRUST_PROXY"] = "yes" },
		"short setup":     func(m map[string]string) { m["LEOPARD_SETUP_TOKEN"] = "abc" },
	}
	for name, mut := range cases {
		m := base()
		mut(m)
		if _, err := FromEnv(env(m)); err == nil {
			t.Errorf("%s: accepted", name)
		} else if strings.Contains(err.Error(), "postgres://") {
			t.Errorf("%s: error leaks the database URL", name)
		}
	}
}

func TestMemStoreNeedsNoDatabase(t *testing.T) {
	c, err := FromEnv(env(map[string]string{"LEOPARD_DEV_MEMSTORE": "1", "LEOPARD_SERVER_KEY": strings.TrimRight(key, "=")}))
	if err != nil || !c.DevMemStore {
		t.Fatalf("%+v %v", c, err)
	}
}
