package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func serve(h http.Handler, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func scrape(t *testing.T, m *httpMetrics) string {
	t.Helper()
	rec := serve(m, "/metrics")
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain; version=0.0.4") {
		t.Fatalf("Content-Type = %q", ct)
	}
	return rec.Body.String()
}

func TestMetricsCountByStatusCode(t *testing.T) {
	m := newHTTPMetrics()
	h := m.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/broken" {
			w.WriteHeader(http.StatusInternalServerError)
			w.WriteHeader(http.StatusOK) // a second WriteHeader must not change the code
			return
		}
		_, _ = w.Write([]byte("ok")) // no WriteHeader: 200
	}))
	serve(h, "/")
	serve(h, "/product/1")
	serve(h, "/broken")

	out := scrape(t, m)
	for _, want := range []string{
		`frontend_http_requests_total{code="200"} 2`,
		`frontend_http_requests_total{code="500"} 1`,
		`frontend_http_request_duration_seconds_bucket{le="+Inf"} 3`,
		`frontend_http_request_duration_seconds_count 3`,
		"# TYPE frontend_http_requests_total counter",
		"# TYPE frontend_http_request_duration_seconds histogram",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("metrics output misses %q:\n%s", want, out)
		}
	}
}

func TestMetricsSkipHealthChecks(t *testing.T) {
	m := newHTTPMetrics()
	h := m.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	serve(h, "/_healthz")
	serve(h, "/robots.txt")
	if out := scrape(t, m); !strings.Contains(out, "frontend_http_request_duration_seconds_count 0") {
		t.Errorf("health checks were counted:\n%s", out)
	}
}

func TestHistogramIsCumulative(t *testing.T) {
	m := newHTTPMetrics()
	m.observe(200, 30*time.Millisecond, true)
	m.observe(200, 700*time.Millisecond, true)
	m.observe(200, 20*time.Second, true) // above every bound
	out := scrape(t, m)
	for _, want := range []string{
		`frontend_http_request_duration_seconds_bucket{le="0.05"} 1`,
		`frontend_http_request_duration_seconds_bucket{le="0.5"} 1`,
		`frontend_http_request_duration_seconds_bucket{le="1"} 2`,
		`frontend_http_request_duration_seconds_bucket{le="10"} 2`,
		`frontend_http_request_duration_seconds_bucket{le="+Inf"} 3`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("metrics output misses %q:\n%s", want, out)
		}
	}
}

func TestFaultPercent(t *testing.T) {
	for in, want := range map[string]int{"": 0, "abc": 0, "-5": 0, "0": 0, " 30 ": 30, "100": 100, "250": 100} {
		if got := faultPercent(in); got != want {
			t.Errorf("faultPercent(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestFaultInjection(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })

	if h := faultInjection(0, ok); serve(h, "/").Code != http.StatusOK {
		t.Fatal("percent 0 must not fault")
	}

	h := faultInjection(30, ok)
	failed := 0
	for i := 0; i < 100; i++ {
		if serve(h, "/").Code == http.StatusInternalServerError {
			failed++
		}
	}
	if failed != 30 {
		t.Errorf("30%% fault: %d of 100 requests failed", failed)
	}

	all := faultInjection(100, ok)
	if serve(all, "/_healthz").Code != http.StatusOK {
		t.Error("health checks must never be faulted (the pods must stay Ready)")
	}
}
