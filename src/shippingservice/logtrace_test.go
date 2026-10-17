package main

// Tests of logtrace.go (ADR 0011). The same file is in frontend, checkoutservice,
// productcatalogservice and shippingservice.

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/sirupsen/logrus"
	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// withTracing installs an SDK tracer provider (as startTracing does) for one test.
func withTracing(t *testing.T) trace.Tracer {
	t.Helper()
	old := otel.GetTracerProvider()
	tp := sdktrace.NewTracerProvider()
	otel.SetTracerProvider(tp)
	t.Cleanup(func() { otel.SetTracerProvider(old); _ = tp.Shutdown(context.Background()) })
	return tp.Tracer("test")
}

// logLines decodes every JSON line of buf.
func logLines(t *testing.T, buf *bytes.Buffer) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if l == "" {
			continue
		}
		m := map[string]any{}
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("not a JSON log line: %q", l)
		}
		out = append(out, m)
	}
	return out
}

// assertTraceFields checks that every line carries the span's IDs.
func assertTraceFields(t *testing.T, lines []map[string]any, sc trace.SpanContext) {
	t.Helper()
	if len(lines) == 0 {
		t.Fatal("no log line")
	}
	for _, l := range lines {
		if l["trace_id"] != sc.TraceID().String() || l["span_id"] != sc.SpanID().String() || l["trace_flags"] != sc.TraceFlags().String() {
			t.Errorf("want trace_id %s span_id %s trace_flags %s, got %v", sc.TraceID(), sc.SpanID(), sc.TraceFlags(), l)
		}
	}
}

func assertNoTraceFields(t *testing.T, lines []map[string]any) {
	t.Helper()
	for _, l := range lines {
		for _, k := range []string{"trace_id", "span_id", "trace_flags"} {
			if _, ok := l[k]; ok {
				t.Errorf("%s should be absent: %v", k, l)
			}
		}
	}
}

func testLogger(buf *bytes.Buffer) *logrus.Logger {
	l := logrus.New()
	l.Out, l.Formatter, l.Level = buf, &logrus.JSONFormatter{}, logrus.DebugLevel
	l.AddHook(traceLogHook{})
	return l
}

func TestTraceLogHook(t *testing.T) {
	tracer := withTracing(t)
	var buf bytes.Buffer
	logger := testLogger(&buf)

	ctx, span := tracer.Start(context.Background(), "request")
	logger.WithContext(ctx).WithField("orderId", "o-1").Info("inside a span")
	span.End()
	inside := logLines(t, &buf)
	assertTraceFields(t, inside, span.SpanContext())
	if inside[0]["trace_flags"] != "01" {
		t.Errorf(`want trace_flags "01" (sampled), got %v`, inside[0]["trace_flags"])
	}
	if inside[0]["orderId"] != "o-1" || inside[0]["msg"] != "inside a span" {
		t.Errorf("the existing fields must stay: %v", inside[0])
	}
	if id, _ := inside[0]["trace_id"].(string); len(id) != 32 || strings.ToLower(id) != id {
		t.Errorf("trace_id must be 32 lower-case hex characters: %q", id)
	}

	buf.Reset()
	logger.WithContext(context.Background()).Info("context without a span")
	logger.Info("no context")
	assertNoTraceFields(t, logLines(t, &buf))
}

// Tracing off (prod): a traceparent sent by a client still ends up in the context (the W3C
// propagator always runs), but its IDs must not reach the logs.
func TestTraceLogHookTracingOff(t *testing.T) {
	sc := trace.NewSpanContext(trace.SpanContextConfig{
		TraceID: trace.TraceID{0x4b, 0xf9, 0x2f, 0x35}, SpanID: trace.SpanID{0x00, 0xf0, 0x67},
		TraceFlags: trace.FlagsSampled, Remote: true,
	})
	ctx := trace.ContextWithRemoteSpanContext(context.Background(), sc)
	old := otel.GetTracerProvider()
	otel.SetTracerProvider(trace.NewNoopTracerProvider()) // tracing off, as in prod
	t.Cleanup(func() { otel.SetTracerProvider(old) })
	ctx, span := otel.Tracer("test").Start(ctx, "request")
	defer span.End()
	if !trace.SpanContextFromContext(ctx).IsValid() {
		t.Fatal("the client's span context should be in the context (the case this test covers)")
	}
	var buf bytes.Buffer
	testLogger(&buf).WithContext(ctx).Info("tracing off")
	assertNoTraceFields(t, logLines(t, &buf))
}

// Tracing on, parent not sampled (ParentBased keeps the parent's decision): the span is valid
// but not sampled, so the line says trace_flags "00".
func TestTraceLogHookNotSampled(t *testing.T) {
	tracer := withTracing(t)
	parent := trace.NewSpanContext(trace.SpanContextConfig{
		TraceID: trace.TraceID{0x4b, 0xf9, 0x2f, 0x35}, SpanID: trace.SpanID{0x00, 0xf0, 0x67}, Remote: true,
	})
	ctx, span := tracer.Start(trace.ContextWithRemoteSpanContext(context.Background(), parent), "request")
	defer span.End()
	var buf bytes.Buffer
	testLogger(&buf).WithContext(ctx).Info("unsampled")
	lines := logLines(t, &buf)
	assertTraceFields(t, lines, span.SpanContext())
	if lines[0]["trace_flags"] != "00" {
		t.Errorf(`want trace_flags "00", got %v`, lines[0]["trace_flags"])
	}
}
