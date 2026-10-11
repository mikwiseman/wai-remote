package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"math/big"
)

type Hello struct {
	Type      string `json:"type"`
	Role      string `json:"role"`
	HostID    string `json:"hostID"`
	PeerID    string `json:"peerID"`
	PublicKey string `json:"publicKey"`
	Signature string `json:"signature"`
}

func authenticate(h Hello, nonce string) bool {
	if h.Type != "hello" || (h.Role != "host" && h.Role != "viewer") || len(h.HostID) != 64 || len(h.PeerID) != 64 || len(h.PublicKey) > 100 || len(h.Signature) > 100 {
		return false
	}
	if _, err := hex.DecodeString(h.HostID); err != nil {
		return false
	}
	pub, err := base64.RawURLEncoding.DecodeString(h.PublicKey)
	if err != nil || len(pub) != 65 {
		return false
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), pub)
	if x == nil {
		return false
	}
	id := sha256.Sum256(pub)
	if hex.EncodeToString(id[:]) != h.PeerID || (h.Role == "host" && h.HostID != h.PeerID) {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(h.Signature)
	if err != nil || len(sig) != 64 {
		return false
	}
	digest := sha256.Sum256([]byte("wai-remote/signal/v1\x00" + h.Role + "\n" + h.HostID + "\n" + h.PeerID + "\n" + nonce))
	return ecdsa.Verify(&ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
}
