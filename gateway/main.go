// The gateway forwards authenticated signaling only. Media and input travel over WebRTC.
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

type envelope struct {
	Type string          `json:"type"`
	From string          `json:"from,omitempty"`
	To   string          `json:"to,omitempty"`
	Body json.RawMessage `json:"body,omitempty"`
}
type client struct {
	hello Hello
	conn  *websocket.Conn
}
type hub struct {
	mu        sync.Mutex
	hosts     map[string]*client
	viewers   map[string]*client
	ice       *iceConfiguration
	relay     *relayIssuer
	admission *admission
}

func newHub() *hub                       { return &hub{hosts: map[string]*client{}, viewers: map[string]*client{}} }
func viewerKey(host, peer string) string { return host + "/" + peer }
func (c *client) send(v any) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return wsjson.Write(ctx, c.conn, v)
}

func (h *hub) serve(w http.ResponseWriter, r *http.Request) {
	if h.admission != nil {
		ip := r.Header.Get("X-Real-IP")
		if net.ParseIP(ip) == nil {
			http.Error(w, "trusted proxy required", http.StatusForbidden)
			return
		}
		if !h.admission.enter(ip, time.Now()) {
			http.Error(w, "Please try again shortly", http.StatusTooManyRequests)
			return
		}
		defer h.admission.leave(ip)
	}
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return
	}
	defer c.CloseNow()
	c.SetReadLimit(128 * 1024)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	nonceBytes := make([]byte, 32)
	if _, err = rand.Read(nonceBytes); err != nil {
		cancel()
		return
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
	err = wsjson.Write(ctx, c, map[string]string{"type": "challenge", "nonce": nonce})
	var hello Hello
	if err == nil {
		err = wsjson.Read(ctx, c, &hello)
	}
	cancel()
	// An interrupted or timed-out handshake is a transport failure. Only a
	// complete hello with an invalid signature is an authentication rejection.
	if err != nil {
		return
	}
	if !authenticate(hello, nonce) {
		c.Close(websocket.StatusPolicyViolation, "authentication failed")
		return
	}
	current := &client{hello: hello, conn: c}
	h.mu.Lock()
	registered := false
	hostUnavailable := hello.Role == "viewer" && h.relay != nil && h.hosts[hello.HostID] == nil
	if hello.Role == "host" {
		if h.hosts[hello.HostID] == nil && len(h.hosts) < 100 {
			h.hosts[hello.HostID] = current
			registered = true
		}
	} else if !hostUnavailable && h.viewers[viewerKey(hello.HostID, hello.PeerID)] == nil && len(h.viewers) < 400 {
		h.viewers[viewerKey(hello.HostID, hello.PeerID)] = current
		registered = true
	}
	h.mu.Unlock()
	if !registered {
		if hostUnavailable {
			_ = current.send(map[string]string{"type": "unavailable"})
			c.Close(websocket.StatusNormalClosure, "host unavailable")
			return
		}
		c.Close(websocket.StatusPolicyViolation, "identity already connected or capacity reached")
		return
	}
	defer func() {
		h.mu.Lock()
		if hello.Role == "host" {
			delete(h.hosts, hello.HostID)
		} else {
			delete(h.viewers, viewerKey(hello.HostID, hello.PeerID))
		}
		h.mu.Unlock()
	}()
	ready := map[string]any{"type": "ready"}
	lastRelay := time.Now()
	if h.relay != nil {
		ready["ice"] = h.relay.forClient(hello, lastRelay)
	}
	if h.ice != nil {
		if h.ice.ExpiresAt <= time.Now().Unix() {
			c.Close(websocket.StatusPolicyViolation, "relay credentials expired")
			return
		}
		ready["ice"] = h.ice
	}
	if current.send(ready) != nil {
		return
	}
	windowStart := time.Now()
	count := 0
	for {
		readCtx, readCancel := context.WithTimeout(context.Background(), 75*time.Second)
		var msg envelope
		err = wsjson.Read(readCtx, c, &msg)
		readCancel()
		if err != nil {
			return
		}
		if time.Since(windowStart) > time.Second {
			windowStart = time.Now()
			count = 0
		}
		count++
		if count > 100 {
			c.Close(websocket.StatusPolicyViolation, "signaling rate limit")
			return
		}
		if msg.Type == "ping" {
			if h.relay != nil && hello.Role == "host" && time.Since(lastRelay) >= 30*time.Minute {
				lastRelay = time.Now()
				if current.send(map[string]any{"type": "relay", "ice": h.relay.forClient(hello, lastRelay)}) != nil {
					return
				}
			}
			if current.send(map[string]string{"type": "pong"}) != nil {
				return
			}
			continue
		}
		if msg.Type != "offer" && msg.Type != "answer" && msg.Type != "ice" && msg.Type != "reject" && msg.Type != "close" {
			continue
		}
		if hello.Role == "viewer" && msg.Type != "offer" && msg.Type != "ice" && msg.Type != "close" {
			continue
		}
		if hello.Role == "host" && msg.Type == "offer" {
			continue
		}
		h.mu.Lock()
		var target *client
		if hello.Role == "host" {
			target = h.viewers[viewerKey(hello.HostID, msg.To)]
		} else {
			target = h.hosts[hello.HostID]
		}
		h.mu.Unlock()
		if target == nil {
			_ = current.send(map[string]string{"type": "unavailable"})
			continue
		}
		msg.From = hello.PeerID
		msg.To = ""
		if target.send(msg) != nil {
			_ = current.send(map[string]string{"type": "unavailable"})
		}
	}
}

func main() {
	address := flag.String("listen", "127.0.0.1:8788", "Bind address; keep loopback for local development")
	assets := flag.String("web", "../web/dist", "Built viewer directory")
	icePath := flag.String("ice-config", "", "Private short-lived ICE JSON; requires loopback behind SSH")
	relayPath := flag.String("relay-secret", "", "Coturn REST secret file; requires the trusted loopback HTTPS proxy")
	relayIP := flag.String("relay-ip", "", "Public IPv4 of coturn")
	releases := flag.String("releases", "", "Public downloads and signed updates directory")
	flag.Parse()
	if *icePath != "" && *relayPath != "" {
		log.Fatal("choose private ICE or public relay")
	}
	relay, err := loadRelay(*relayPath, *address, *relayIP)
	if err != nil {
		log.Fatal(err)
	}
	ice, err := loadICEConfig(*icePath, *address)
	if err != nil {
		log.Fatal(err)
	}
	if _, err := os.Stat(*assets + "/index.html"); err != nil {
		log.Fatal("viewer missing: run npm run build in web first")
	}
	mux := http.NewServeMux()
	h := newHub()
	h.ice = ice
	h.relay = relay
	if relay != nil {
		h.admission = newAdmission()
	}
	mux.HandleFunc("/signal", h.serve)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true,"service":"wai-remote-signaling","protocol":1}`))
	})
	mux.Handle("/", http.FileServer(http.Dir(*assets)))
	if *releases != "" {
		for _, prefix := range []string{"/downloads/", "/updates/"} {
			root := http.Dir(filepath.Join(*releases, prefix))
			files := http.StripPrefix(prefix, http.FileServer(root))
			mux.Handle(prefix, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				f, err := root.Open(r.URL.Path[len(prefix):])
				if err != nil {
					http.NotFound(w, r)
					return
				}
				info, err := f.Stat()
				f.Close()
				if err != nil || info.IsDir() {
					http.NotFound(w, r)
					return
				}
				files.ServeHTTP(w, r)
			}))
		}
	}
	handler := viewerHeaders(mux)
	log.Printf("WAI Remote gateway listening on %s", *address)
	server := &http.Server{Addr: *address, Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 16 * 1024}
	log.Fatal(server.ListenAndServe())
}

func viewerHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Permissions-Policy", "camera=(self), microphone=(), geolocation=()")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self' ws://localhost:* ws://127.0.0.1:*; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
