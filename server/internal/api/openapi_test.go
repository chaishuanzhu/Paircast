package api

import (
	"net/http"
	"strings"
	"testing"

	"github.com/chaishuanzhu/Paircast/server/api/openapi"
	"github.com/chaishuanzhu/Paircast/server/internal/account"
)

// Register（含账号接口）挂载的每个路由都必须出现在 api/openapi/openapi.yaml 里。
func TestSpecCoversRoutes(t *testing.T) {
	spec := openapi.Spec
	mux := &recordingMux{}
	NewServer(nil, nil, nil).Register(mux)
	account.NewHandler(nil, "").Register(mux)
	if len(mux.routes) < 10 {
		t.Fatalf("found only %d routes", len(mux.routes))
	}
	for _, route := range mux.routes {
		if !strings.Contains(string(spec), "\n  "+route+":") {
			t.Errorf("route %s is not documented in api/openapi/openapi.yaml", route)
		}
	}
}

type recordingMux struct{ routes []string }

func (m *recordingMux) HandleFunc(pattern string, _ func(http.ResponseWriter, *http.Request)) {
	m.routes = append(m.routes, pattern)
}
