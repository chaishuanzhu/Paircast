package openapi

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func get(h http.Handler, path string) (*http.Response, string) {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	res := rec.Result()
	body, _ := io.ReadAll(res.Body)
	return res, string(body)
}

func TestHandlerServesSpecAndUI(t *testing.T) {
	h := Handler("/swagger/")

	res, body := get(h, "/swagger/openapi.yaml")
	if res.StatusCode != http.StatusOK || !strings.HasPrefix(body, "openapi: 3.") {
		t.Fatalf("spec: status %d, body starts %.20q", res.StatusCode, body)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/yaml") {
		t.Errorf("spec content type = %q", ct)
	}

	res, body = get(h, "/swagger/")
	if res.StatusCode != http.StatusOK || !strings.Contains(body, "/swagger/openapi.yaml") {
		t.Fatalf("ui: status %d, missing spec URL", res.StatusCode)
	}
}
