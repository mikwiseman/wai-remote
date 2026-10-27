package main

import (
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type relayIssuer struct {
	secret []byte
	stun   string
	urls   []string
}

func loadRelay(path, address, publicIP string) (*relayIssuer, error) {
	if path == "" {
		return nil, nil
	}
	host, _, err := net.SplitHostPort(address)
	if err != nil || !net.ParseIP(host).IsLoopback() {
		return nil, errors.New("relay issuer must listen behind the trusted loopback proxy")
	}
	ip := net.ParseIP(publicIP)
	if ip == nil || ip.To4() == nil || ip.IsPrivate() || ip.IsLoopback() || ip.IsUnspecified() {
		return nil, errors.New("relay needs a public IPv4 address")
	}
	secret, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	secret = []byte(strings.TrimSpace(string(secret)))
	if len(secret) < 32 || len(secret) > 256 {
		return nil, errors.New("relay secret must contain 32 to 256 bytes")
	}
	return &relayIssuer{secret: secret, stun: "stun:" + ip.String() + ":3478", urls: []string{"turn:" + ip.String() + ":3478?transport=udp", "turn:" + ip.String() + ":3478?transport=tcp"}}, nil
}

func (r *relayIssuer) issue(peer string, now time.Time) *iceConfiguration {
	expiry := now.Add(time.Hour).Unix()
	id := sha256.Sum256([]byte(peer))
	username := strconv.FormatInt(expiry, 10) + ":" + hex.EncodeToString(id[:16])
	mac := hmac.New(sha1.New, r.secret)
	mac.Write([]byte(username))
	// Direct VPN paths can keep video flowing while SCTP commands stall for
	// seconds. Use the measured UDP relay route, retaining TCP as a fallback.
	return &iceConfiguration{Servers: []iceServer{{URLs: r.urls, Username: username, Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil))}}, Policy: "relay", ExpiresAt: expiry}
}

func (r *relayIssuer) forClient(hello Hello, now time.Time) *iceConfiguration {
	ice := r.issue(hello.PeerID, now)
	if hello.ICEVersion >= 4 {
		// Peer to peer first. STUN must answer from Russia: VPNs used there send
		// Russian addresses directly, so the reflexive address is the device's own
		// network, not a foreign VPN exit (stun.novofon.ru, stun.trueconf.ru).
		// The UDP relay stays only for networks that cannot connect directly.
		ice.Policy = "all"
		ice.Servers[0].URLs = []string{"stun:37.139.38.244:3478", "stun:79.143.67.226:3478", r.urls[0]}
	} else if hello.ICEVersion >= 3 {
		// These apps skip VPN adapters, whose direct routes stalled SCTP input.
		// Try the physical network first; the relays remain the fallback.
		ice.Policy = "all"
		ice.Servers[0].URLs = append([]string{r.stun}, r.urls...)
	} else if hello.ICEVersion < 2 {
		// Released clients require every interface to finish gathering. Preserve
		// their working relay configuration until the desktop app is updated.
		ice.Policy = "relay"
		ice.Servers[0].URLs = []string{r.urls[len(r.urls)-1]}
	}
	return ice
}

type admissionEntry struct {
	active, attempts int
	since            time.Time
}
type admission struct {
	mu      sync.Mutex
	clients map[string]*admissionEntry
}

func newAdmission() *admission { return &admission{clients: map[string]*admissionEntry{}} }
func (a *admission) enter(ip string, now time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	for key, entry := range a.clients {
		if entry.active == 0 && now.Sub(entry.since) > time.Minute {
			delete(a.clients, key)
		}
	}
	entry := a.clients[ip]
	if entry == nil {
		if len(a.clients) >= 2048 {
			return false
		}
		entry = &admissionEntry{since: now}
		a.clients[ip] = entry
	}
	if now.Sub(entry.since) >= time.Minute {
		entry.attempts = 0
		entry.since = now
	}
	entry.attempts++
	if entry.active >= 8 || entry.attempts > 30 {
		return false
	}
	entry.active++
	return true
}
func (a *admission) leave(ip string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if entry := a.clients[ip]; entry != nil && entry.active > 0 {
		entry.active--
	}
}
