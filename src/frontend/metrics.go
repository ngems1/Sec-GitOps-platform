package main

// Prometheus metrics of the frontend's HTTP traffic, for the canary analysis of Argo
// Rollouts (helm-chart/templates/frontend-rollout.yaml, ADR 0008):
//
//	frontend_http_requests_total{code="200"}           counter, by status code
//	frontend_http_request_duration_seconds_bucket{le}   histogram (+ _sum, _count)
//
// Written in the Prometheus text format by hand, so the frontend needs no new Go module.
// Served on METRICS_PORT (its own listener: not behind the Service or the ALB). Health
// checks and robots.txt are not counted, so ALB and kubelet probes cannot hide errors.
//
// FAULT_INJECT_500_PERCENT (0-100, default 0) answers that share of requests with a 500,
// for the failing-canary demo (docs/week3/RUNBOOK.md section 10). Health checks are never
// faulted, so the pods stay Ready and only the analysis can stop the canary.

import (
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Upper bounds in seconds; the analysis reads p95 against 1 s (the shop's latency SLO).
var latencyBuckets = []float64{0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

type httpMetrics struct {
	mu       sync.Mutex
	requests map[int]uint64 // by status code
	buckets  []uint64       // per latencyBuckets bound, not cumulative
	count    uint64
	sum      float64
}

func newHTTPMetrics() *httpMetrics {
	return &httpMetrics{requests: map[int]uint64{}, buckets: make([]uint64, len(latencyBuckets))}
}

// countedPath reports whether requests to this path are measured.
func countedPath(path string) bool {
	return path != "/_healthz" && path != "/robots.txt"
}

func (m *httpMetrics) observe(code int, d time.Duration) {
	s := d.Seconds()
	m.mu.Lock()
	defer m.mu.Unlock()
	m.requests[code]++
	m.count++
	m.sum += s
	for i, le := range latencyBuckets {
		if s <= le {
			m.buckets[i]++
			break
		}
	}
}

// statusRecorder remembers the first status code written (200 when none is).
type statusRecorder struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (s *statusRecorder) WriteHeader(code int) {
	if !s.wrote {
		s.status, s.wrote = code, true
	}
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	s.wrote = true
	return s.ResponseWriter.Write(b)
}

// middleware measures every request to a counted path.
func (m *httpMetrics) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !countedPath(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		m.observe(rec.status, time.Since(start))
	})
}

func formatFloat(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }

// ServeHTTP writes the metrics in the Prometheus text exposition format.
func (m *httpMetrics) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	codes := make([]int, 0, len(m.requests))
	for c := range m.requests {
		codes = append(codes, c)
	}
	sort.Ints(codes)
	var b strings.Builder
	b.WriteString("# HELP frontend_http_requests_total HTTP requests answered by the frontend, by status code (health checks excluded).\n")
	b.WriteString("# TYPE frontend_http_requests_total counter\n")
	for _, c := range codes {
		fmt.Fprintf(&b, "frontend_http_requests_total{code=\"%d\"} %d\n", c, m.requests[c])
	}
	b.WriteString("# HELP frontend_http_request_duration_seconds Time to answer an HTTP request (health checks excluded).\n")
	b.WriteString("# TYPE frontend_http_request_duration_seconds histogram\n")
	var cumulative uint64
	for i, le := range latencyBuckets {
		cumulative += m.buckets[i]
		fmt.Fprintf(&b, "frontend_http_request_duration_seconds_bucket{le=\"%s\"} %d\n", formatFloat(le), cumulative)
	}
	fmt.Fprintf(&b, "frontend_http_request_duration_seconds_bucket{le=\"+Inf\"} %d\n", m.count)
	fmt.Fprintf(&b, "frontend_http_request_duration_seconds_sum %s\n", formatFloat(m.sum))
	fmt.Fprintf(&b, "frontend_http_request_duration_seconds_count %d\n", m.count)
	m.mu.Unlock()

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = w.Write([]byte(b.String()))
}

// faultPercent reads FAULT_INJECT_500_PERCENT: 0 when empty or invalid, at most 100.
func faultPercent(v string) int {
	p, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || p < 0 {
		return 0
	}
	if p > 100 {
		return 100
	}
	return p
}

// faultInjection answers percent% of the counted requests with a 500 (evenly spread: in
// every 100 requests, the first percent fail). percent 0 returns next unchanged.
func faultInjection(percent int, next http.Handler) http.Handler {
	if percent <= 0 {
		return next
	}
	var n uint64
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if countedPath(r.URL.Path) && int(atomic.AddUint64(&n, 1)%100) < percent {
			http.Error(w, "fault injected (FAULT_INJECT_500_PERCENT)", http.StatusInternalServerError)
			return
		}
		next.ServeHTTP(w, r)
	})
}
