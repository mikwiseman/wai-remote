package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func httpHandler(h *hub) http.Handler { return http.HandlerFunc(h.serve) }

func TestMalformedHandshakeIsNotReportedAsAnInvalidDeviceSignature(t *testing.T) {
	h := newHub()
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
	if err = wsjson.Read(ctx, c, &challenge); err != nil {
		t.Fatal(err)
	}
	if err = wsjson.Write(ctx, c, "not a hello object"); err != nil {
		t.Fatal(err)
	}
	var reply map[string]any
	err = wsjson.Read(ctx, c, &reply)
	if err == nil || strings.Contains(err.Error(), "authentication failed") {
		t.Fatalf("Malformed transport data must close without claiming an invalid signature: %v", err)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.hosts) != 0 || len(h.viewers) != 0 {
		t.Fatal("Malformed hello registered a device")
	}
}

func TestUDPRelayRequiresClientCapabilityAndPreservesReliableRouting(t *testing.T) {
	for _, version := range []int{0, 2, 3, 4} {
		h := newHub()
		h.relay = &relayIssuer{secret: []byte(strings.Repeat("s", 32)), stun: "stun:203.0.113.1:3478", urls: []string{"turn:203.0.113.1:3478?transport=udp", "turn:203.0.113.1:3478?transport=tcp"}}
		server := httptest.NewServer(httpHandler(h))
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
		if err != nil {
			t.Fatal(err)
		}
		var challenge map[string]string
		if err = wsjson.Read(ctx, c, &challenge); err != nil {
			t.Fatal(err)
		}
		hello := signedHello(t, "host", challenge["nonce"])
		data, _ := json.Marshal(hello)
		var wire map[string]any
		_ = json.Unmarshal(data, &wire)
		wire["iceVersion"] = version
		if err = wsjson.Write(ctx, c, wire); err != nil {
			t.Fatal(err)
		}
		var ready struct {
			ICE iceConfiguration `json:"ice"`
		}
		if err = wsjson.Read(ctx, c, &ready); err != nil {
			t.Fatal(err)
		}
		if version == 0 && (ready.ICE.Policy != "relay" || len(ready.ICE.Servers[0].URLs) != 1 || !strings.HasSuffix(ready.ICE.Servers[0].URLs[0], "transport=tcp")) {
			t.Error("Old apps must retain their working TCP relay configuration until they can handle partial ICE gathering")
		}
		if version == 2 && (ready.ICE.Policy != "relay" || len(ready.ICE.Servers[0].URLs) != 2) {
			t.Error("Updated apps need UDP with TCP fallback, while avoiding direct VPN routes that stall SCTP input")
		}
		if version == 3 && (ready.ICE.Policy != "all" || strings.Join(ready.ICE.Servers[0].URLs, " ") != "stun:203.0.113.1:3478 turn:203.0.113.1:3478?transport=udp turn:203.0.113.1:3478?transport=tcp") {
			t.Errorf("Apps that skip VPN adapters should try a direct route first and keep both relays, got %+v", ready.ICE)
		}
		if version == 4 && (ready.ICE.Policy != "all" || strings.Join(ready.ICE.Servers[0].URLs, " ") != "stun:37.139.38.244:3478 stun:79.143.67.226:3478 turn:203.0.113.1:3478?transport=udp") {
			t.Errorf("Peer-to-peer apps need Moscow STUN, which a VPN routes directly, and only the UDP relay, got %+v", ready.ICE)
		}
		c.CloseNow()
		cancel()
		server.Close()
	}
}

func connectTest(t *testing.T, url, role, host string) (*websocket.Conn, Hello) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.CloseNow() })
	var challenge map[string]string
	if err = wsjson.Read(ctx, c, &challenge); err != nil {
		t.Fatal(err)
	}
	var h Hello
	if host == "" {
		h = signedHello(t, role, challenge["nonce"])
	} else {
		h = signedHello(t, role, challenge["nonce"], host)
	}
	if err = wsjson.Write(ctx, c, h); err != nil {
		t.Fatal(err)
	}
	var ready map[string]string
	if err = wsjson.Read(ctx, c, &ready); err != nil {
		t.Fatal(err)
	}
	if ready["type"] != "ready" {
		t.Fatal(ready)
	}
	return c, h
}
func TestRoutesByAuthenticatedHostAndRewritesSender(t *testing.T) {
	h := newHub()
	server := httptest.NewServer(httpHandler(h))
	defer server.Close()
	url := "ws" + strings.TrimPrefix(server.URL, "http")
	hostA, a := connectTest(t, url, "host", "")
	_, b := connectTest(t, url, "host", "")
	viewerA, v := connectTest(t, url, "viewer", a.HostID)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	err := wsjson.Write(ctx, viewerA, envelope{Type: "offer", From: b.HostID, To: b.HostID})
	if err != nil {
		t.Fatal(err)
	}
	var received envelope
	if err = wsjson.Read(ctx, hostA, &received); err != nil {
		t.Fatal(err)
	}
	if received.From != v.PeerID || received.To != "" || received.Type != "offer" {
		t.Fatalf("untrusted routing fields survived: %+v", received)
	}
}
func TestHostCannotRouteToViewerPairedWithAnotherHost(t *testing.T) {
	h := newHub()
	server := httptest.NewServer(httpHandler(h))
	defer server.Close()
	url := "ws" + strings.TrimPrefix(server.URL, "http")
	hostA, _ := connectTest(t, url, "host", "")
	_, b := connectTest(t, url, "host", "")
	_, viewerB := connectTest(t, url, "viewer", b.HostID)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, hostA, envelope{Type: "answer", To: viewerB.PeerID}); err != nil {
		t.Fatal(err)
	}
	var result map[string]string
	if err := wsjson.Read(ctx, hostA, &result); err != nil {
		t.Fatal(err)
	}
	if result["type"] != "unavailable" {
		t.Fatal("cross-host routing accepted")
	}
}

func TestOfflineHostReportsUnavailableWithoutIssuingRelayCredentials(t *testing.T) {
	h := newHub()
	h.relay = &relayIssuer{secret: []byte(strings.Repeat("s", 32)), urls: []string{"turn:203.0.113.1:3478?transport=udp"}}
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
	if err = wsjson.Read(ctx, c, &challenge); err != nil {
		t.Fatal(err)
	}
	hello := signedHello(t, "viewer", challenge["nonce"], strings.Repeat("a", 64))
	if err = wsjson.Write(ctx, c, hello); err != nil {
		t.Fatal(err)
	}
	var response map[string]any
	if err = wsjson.Read(ctx, c, &response); err != nil {
		t.Fatalf("offline host must report its state before closing: %v", err)
	}
	if len(response) != 1 || response["type"] != "unavailable" {
		t.Fatalf("offline response must not include relay credentials: %v", response)
	}
	h.mu.Lock()
	registered := len(h.viewers)
	h.mu.Unlock()
	if registered != 0 {
		t.Fatal("offline connection occupied a viewer slot")
	}
}
