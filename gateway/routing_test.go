package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func httpHandler(h *hub) http.Handler { return http.HandlerFunc(h.serve) }

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
