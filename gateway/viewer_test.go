package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestViewerCanAskForQRCameraWithoutMicrophoneOrLocation(t *testing.T) {
	response := httptest.NewRecorder()
	viewerHeaders(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/", nil))
	policy := map[string]string{}
	for _, directive := range strings.Split(response.Header().Get("Permissions-Policy"), ",") {
		name, value, _ := strings.Cut(strings.TrimSpace(directive), "=")
		policy[name] = value
	}
	if policy["camera"] != "(self)" {
		t.Fatalf("The viewer must be able to request its own QR camera; got %q", policy["camera"])
	}
	for _, permission := range []string{"microphone", "geolocation"} {
		if policy[permission] != "()" {
			t.Errorf("QR scanning does not need %s: %q", permission, policy[permission])
		}
	}
}
