package main

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/sirupsen/logrus"
)

// The request logs hold no session ID, user agent, client IP or query string, even at Debug
// level (ADR 0011).
func TestRequestLogsHoldNoPersonalData(t *testing.T) {
	var buf bytes.Buffer
	logger := logrus.New()
	logger.Out, logger.Level = &buf, logrus.DebugLevel
	logger.Formatter = &logrus.JSONFormatter{}

	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// a handler logging through the request logger, as handlers.go does
		r.Context().Value(ctxKeyLog{}).(logrus.FieldLogger).Debug("handler line")
		w.WriteHeader(http.StatusOK)
	})
	handler := ensureSessionID(&logHandler{log: logger, next: inner})

	req := httptest.NewRequest(http.MethodGet, "/assistant?q=my+secret+question", nil)
	req.AddCookie(&http.Cookie{Name: cookieSessionID, Value: "5f1c2a77-session"})
	req.Header.Set("User-Agent", "Mozilla/5.0 (UniqueAgent/9.9)")
	req.Header.Set("X-Forwarded-For", "203.0.113.7")
	req.RemoteAddr = "198.51.100.4:51000"
	handler.ServeHTTP(httptest.NewRecorder(), req)

	logs := buf.String()
	if !strings.Contains(logs, `"request complete"`) || !strings.Contains(logs, `"level":"info"`) {
		t.Fatalf("want an Info request log line:\n%s", logs)
	}
	if !strings.Contains(logs, `"http.req.path":"/assistant"`) {
		t.Errorf("want the path without its query string:\n%s", logs)
	}
	for _, secret := range []string{"5f1c2a77-session", `"session"`, "UniqueAgent", "203.0.113.7", "198.51.100.4", "secret", "q="} {
		if strings.Contains(logs, secret) {
			t.Errorf("logs contain %q:\n%s", secret, logs)
		}
	}
}

// The request logger (logHandler) carries the request span's IDs on every line, the handlers'
// own lines included (ADR 0011).
func TestRequestLogsCarryTraceIDs(t *testing.T) {
	tracer := withTracing(t)
	var buf bytes.Buffer
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Context().Value(ctxKeyLog{}).(logrus.FieldLogger).Info("handler line")
		w.WriteHeader(http.StatusOK)
	})
	handler := ensureSessionID(&logHandler{log: testLogger(&buf), next: inner})

	ctx, span := tracer.Start(context.Background(), "GET /") // the server span tracedHandler starts
	req := httptest.NewRequest(http.MethodGet, "/", nil).WithContext(ctx)
	handler.ServeHTTP(httptest.NewRecorder(), req)
	span.End()

	lines := logLines(t, &buf)
	if len(lines) != 3 { // request started (Debug), handler line, request complete
		t.Fatalf("want 3 lines, got %d: %v", len(lines), lines)
	}
	assertTraceFields(t, lines, span.SpanContext())
}
