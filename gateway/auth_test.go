package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"testing"
)

func signedHello(t *testing.T, role, nonce string, host ...string) Hello {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pub := elliptic.Marshal(elliptic.P256(), key.X, key.Y)
	id := sha256.Sum256(pub)
	h := Hello{Type: "hello", Role: role, HostID: hex.EncodeToString(id[:]), PeerID: hex.EncodeToString(id[:]), PublicKey: base64.RawURLEncoding.EncodeToString(pub)}
	if len(host) > 0 {
		h.HostID = host[0]
	}
	digest := sha256.Sum256([]byte("wai-remote/signal/v1\x00" + role + "\n" + h.HostID + "\n" + h.PeerID + "\n" + nonce))
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	h.Signature = base64.RawURLEncoding.EncodeToString(sig)
	return h
}
func TestAuthenticationBindsRoleHostAndFreshChallenge(t *testing.T) {
	h := signedHello(t, "host", "fresh")
	if !authenticate(h, "fresh") {
		t.Fatal("valid identity rejected")
	}
	if authenticate(h, "old") {
		t.Fatal("replayed challenge accepted")
	}
	h.Role = "viewer"
	if authenticate(h, "fresh") {
		t.Fatal("changed role accepted")
	}
	h.Role = "host"
	h.HostID = "other"
	if authenticate(h, "fresh") {
		t.Fatal("host substitution accepted")
	}
}
func TestMalformedKeysNeverAuthenticate(t *testing.T) {
	h := signedHello(t, "host", "fresh")
	h.PublicKey = "AA"
	if authenticate(h, "fresh") {
		t.Fatal("invalid point accepted")
	}
	h = signedHello(t, "host", "fresh")
	h.Signature = "AA"
	if authenticate(h, "fresh") {
		t.Fatal("short signature accepted")
	}
}
