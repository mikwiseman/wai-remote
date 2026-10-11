package main

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

func TestRelayCredentialsAreBoundedAndDistinct(t *testing.T) {
	r := &relayIssuer{secret: []byte(strings.Repeat("s", 32)), url: "turn:203.0.113.1:3478?transport=tcp"}
	now := time.Unix(1700000000, 0)
	a, b := r.issue("alice", now), r.issue("bob", now)
	if a.Policy != "relay" || a.ExpiresAt != now.Add(time.Hour).Unix() || a.Servers[0].Username == b.Servers[0].Username {
		t.Fatal("unbounded or shared credential")
	}
	mac := hmac.New(sha1.New, r.secret)
	mac.Write([]byte(a.Servers[0].Username))
	if a.Servers[0].Credential != base64.StdEncoding.EncodeToString(mac.Sum(nil)) {
		t.Fatal("coturn REST signature mismatch")
	}
	if r.issue("alice", now.Add(31*time.Minute)).Servers[0].Credential == a.Servers[0].Credential {
		t.Fatal("credential did not rotate")
	}
}

func TestAdmissionBoundsAnonymousClients(t *testing.T) {
	a := newAdmission()
	now := time.Now()
	for i := 0; i < 8; i++ {
		if !a.enter("192.0.2.1", now) {
			t.Fatal("normal connection refused")
		}
	}
	if a.enter("192.0.2.1", now) {
		t.Fatal("per-address live limit missing")
	}
	a.leave("192.0.2.1")
	if !a.enter("192.0.2.1", now) {
		t.Fatal("closed slot not reusable")
	}
	for i := 0; i < 30; i++ {
		a.leave("192.0.2.1")
		a.enter("192.0.2.1", now)
	}
	a.leave("192.0.2.1")
	if a.enter("192.0.2.1", now) {
		t.Fatal("handshake rate limit missing")
	}
	if !a.enter("192.0.2.1", now.Add(2*time.Minute)) {
		t.Fatal("rate limit did not recover")
	}
}
