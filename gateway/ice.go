package main

import (
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"os"
	"strings"
	"time"
)

type iceServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username"`
	Credential string   `json:"credential"`
}
type iceConfiguration struct {
	Servers   []iceServer `json:"iceServers"`
	Policy    string      `json:"iceTransportPolicy"`
	ExpiresAt int64       `json:"expiresAt"`
}

// This private test lane distributes credentials only behind an existing SSH
// tunnel. Public deployment needs its own device authorization/allocation policy.
func loadICEConfig(path, address string) (*iceConfiguration, error) {
	if path == "" {
		return nil, nil
	}
	host, _, err := net.SplitHostPort(address)
	if err != nil || !net.ParseIP(host).IsLoopback() {
		return nil, errors.New("private ICE configuration requires a literal loopback listen address")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c iceConfiguration
	if len(data) > 16384 || json.Unmarshal(data, &c) != nil {
		return nil, errors.New("invalid ICE configuration")
	}
	if c.ExpiresAt <= time.Now().Unix() || c.ExpiresAt > time.Now().Add(2*time.Hour).Unix() || len(c.Servers) == 0 || len(c.Servers) > 4 || (c.Policy != "all" && c.Policy != "relay") {
		return nil, errors.New("invalid or expired ICE configuration")
	}
	for _, s := range c.Servers {
		if len(s.URLs) == 0 || len(s.URLs) > 4 || len(s.Username) == 0 || len(s.Username) > 512 || len(s.Credential) == 0 || len(s.Credential) > 512 {
			return nil, errors.New("invalid ICE server")
		}
		for _, raw := range s.URLs {
			scheme, rest, ok := strings.Cut(raw, ":")
			u, err := url.Parse(scheme + "://" + rest)
			if !ok || len(raw) > 512 || (scheme != "turn" && scheme != "turns") || err != nil || u.Hostname() == "" || u.User != nil || u.Path != "" || u.Fragment != "" || (u.RawQuery != "" && u.RawQuery != "transport=udp" && u.RawQuery != "transport=tcp") {
				return nil, errors.New("invalid TURN URL")
			}
		}
	}
	return &c, nil
}
