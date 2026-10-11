package main

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func TestPrivateICEConfigCannotExposeCredentialsOnPublicListener(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ice.json")
	data, _ := json.Marshal(map[string]any{
		"iceServers":         []any{map[string]any{"urls": []string{"turn:relay.example:3478?transport=udp"}, "username": "temporary", "credential": "temporary-password"}},
		"iceTransportPolicy": "relay", "expiresAt": time.Now().Add(time.Hour).Unix(),
	})
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadICEConfig(path, "127.0.0.1:8788"); err != nil {
		t.Fatal(err)
	}
	for _, address := range []string{"0.0.0.0:8788", ":8788", "192.168.1.2:8788"} {
		if _, err := loadICEConfig(path, address); err == nil {
			t.Fatal("relay credential distribution must remain behind SSH", address)
		}
	}
	if err := os.WriteFile(path, []byte(`{"iceServers":[],"iceTransportPolicy":"relay","expiresAt":1}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadICEConfig(path, "127.0.0.1:8788"); err == nil {
		t.Fatal("expired/empty relay accepted")
	}
	if _, err := loadICEConfig("", "0.0.0.0:8788"); err != nil {
		t.Fatal("legacy LAN changed", err)
	}
}

func TestRelayCredentialsRequireFreshDeviceAuthenticationAndExpiry(t *testing.T) {
	for _, test := range []struct {
		name                   string
		authenticated, expired bool
	}{
		{"authenticated", true, false}, {"unauthenticated", false, false}, {"expired", true, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := newHub()
			expires := time.Now().Add(time.Hour).Unix()
			if test.expired {
				expires = 1
			}
			h.ice = &iceConfiguration{Servers: []iceServer{{URLs: []string{"turn:relay.example:3478"}, Username: "temporary", Credential: "not-public"}}, Policy: "relay", ExpiresAt: expires}
			server := httptest.NewServer(httpHandler(h))
			defer server.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer c.CloseNow()
			var challenge map[string]string
			if err := wsjson.Read(ctx, c, &challenge); err != nil {
				t.Fatal(err)
			}
			nonce := challenge["nonce"]
			if !test.authenticated {
				nonce = "stale-challenge"
			}
			if err := wsjson.Write(ctx, c, signedHello(t, "host", nonce)); err != nil {
				t.Fatal(err)
			}
			var ready struct {
				Type string            `json:"type"`
				ICE  *iceConfiguration `json:"ice"`
			}
			err = wsjson.Read(ctx, c, &ready)
			if !test.authenticated || test.expired {
				if err == nil || ready.ICE != nil {
					t.Fatal("relay credentials disclosed without valid authorization")
				}
				if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
					t.Fatal("expected explicit rejection", err)
				}
			} else if err != nil || ready.Type != "ready" || ready.ICE == nil || ready.ICE.Policy != "relay" || ready.ICE.Servers[0].Credential != "not-public" {
				t.Fatal("authenticated relay configuration missing", err)
			}
		})
	}
}
