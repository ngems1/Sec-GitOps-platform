package main

// The frontend is the edge: a client's trace headers never become our trace (tracing.go,
// tracedHandler). These tests send a client traceparent (sampled=00), tracestate and baggage
// through the same chain as main.go and look at the server span, the context the handlers see,
// what would go downstream (what the otelgrpc clients inject) and the request log line.

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gorilla/mux"
	"github.com/sirupsen/logrus"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/baggage"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

const (
	clientTraceID = "4bf92f3577b34da6a3ce929d0e0e4736"
	clientSpanID  = "00f067aa0ba902b7"
	// sampled=00: before this change it made the request invisible in every service
	clientTraceparent = "00-" + clientTraceID + "-" + clientSpanID + "-00"
)

// seen is what the handler saw for one request.
type seen struct {
	ctx        context.Context
	downstream propagation.MapCarrier // what an outgoing call would carry
}

// edgeChain is main.go's chain: tracing, session, request logger, router.
func edgeChain(t *testing.T, logOut *bytes.Buffer) (http.Handler, *seen) {
	t.Helper()
	s := &seen{}
	r := mux.NewRouter()
	r.HandleFunc("/product/{id}", func(w http.ResponseWriter, req *http.Request) {
		s.ctx = req.Context()
		s.downstream = propagation.MapCarrier{}
		otel.GetTextMapPropagator().Inject(req.Context(), s.downstream)
		req.Context().Value(ctxKeyLog{}).(logrus.FieldLogger).Info("product")
		w.WriteHeader(http.StatusOK)
	}).Methods(http.MethodGet)
	logger := testLogger(logOut)
	return tracedHandler(r, ensureSessionID(&logHandler{log: logger, next: r})), s
}

func clientRequest() *http.Request {
	req := httptest.NewRequest(http.MethodGet, "/product/OLJCESPC7Z", nil)
	req.Header.Set("traceparent", clientTraceparent)
	req.Header.Set("tracestate", "vendor=client")
	req.Header.Set("baggage", "session=secret-session,user=jane")
	return req
}

func withPropagator(t *testing.T) {
	old := otel.GetTextMapPropagator()
	otel.SetTextMapPropagator(newPropagator()) // as main.go, tracing on or off
	t.Cleanup(func() { otel.SetTextMapPropagator(old) })
}

func TestEdgeTracingOnNewRootWithLink(t *testing.T) {
	withPropagator(t)
	recorder := tracetest.NewSpanRecorder()
	oldTP := otel.GetTracerProvider()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSampler(newSampler()), sdktrace.WithSpanProcessor(recorder))
	otel.SetTracerProvider(tp)
	t.Cleanup(func() { otel.SetTracerProvider(oldTP) })

	var logs bytes.Buffer
	h, s := edgeChain(t, &logs)
	h.ServeHTTP(httptest.NewRecorder(), clientRequest())

	spans := recorder.Ended()
	if len(spans) != 1 {
		t.Fatalf("want 1 server span, got %d", len(spans))
	}
	span := spans[0]
	sc := span.SpanContext()
	// Inbound sampled=00 still gives a sampled, recorded root span.
	if !sc.IsSampled() || span.Parent().IsValid() {
		t.Errorf("want a sampled root span, got sampled=%v parent=%v", sc.IsSampled(), span.Parent())
	}
	// A new trace ID; the client's context only as a link.
	if sc.TraceID().String() == clientTraceID {
		t.Error("the client chose our trace ID")
	}
	if len(span.Links()) != 1 || span.Links()[0].SpanContext.TraceID().String() != clientTraceID ||
		span.Links()[0].SpanContext.SpanID().String() != clientSpanID {
		t.Errorf("want one link to the client's span context, got %+v", span.Links())
	}
	if sc.TraceState().Len() != 0 {
		t.Errorf("the client's tracestate must not carry over: %q", sc.TraceState().String())
	}
	// Route-named span (as before).
	if span.Name() != "GET /product/{id}" {
		t.Errorf("span name %q", span.Name())
	}
	// Downstream: our trace, sampled, no baggage.
	if want := "00-" + sc.TraceID().String() + "-"; len(s.downstream["traceparent"]) < len(want) || s.downstream["traceparent"][:len(want)] != want {
		t.Errorf("downstream traceparent %q, want our trace %s", s.downstream["traceparent"], sc.TraceID())
	}
	if s.downstream["traceparent"][53:] != "01" {
		t.Errorf("downstream must be sampled: %q", s.downstream["traceparent"])
	}
	if _, ok := s.downstream["baggage"]; ok || baggage.FromContext(s.ctx).Len() != 0 {
		t.Errorf("the client's baggage reached the handler or downstream: %v", s.downstream)
	}
	// The request log line carries our trace, not the client's (logtrace.go).
	lines := logLines(t, &logs)
	var product map[string]any
	for _, l := range lines {
		if l["msg"] == "product" {
			product = l
		}
	}
	if product == nil || product["trace_id"] != sc.TraceID().String() || product["trace_flags"] != "01" {
		t.Errorf("want the product log line with trace_id %s, trace_flags 01: %v", sc.TraceID(), lines)
	}
}

func TestEdgeTracingOffForwardsNothing(t *testing.T) {
	withPropagator(t)
	oldTP := otel.GetTracerProvider()
	otel.SetTracerProvider(trace.NewNoopTracerProvider()) // prod today
	t.Cleanup(func() { otel.SetTracerProvider(oldTP) })

	var logs bytes.Buffer
	h, s := edgeChain(t, &logs)
	h.ServeHTTP(httptest.NewRecorder(), clientRequest())

	if trace.SpanContextFromContext(s.ctx).IsValid() {
		t.Errorf("the client's span context reached the handler: %v", trace.SpanContextFromContext(s.ctx))
	}
	for _, k := range []string{"traceparent", "tracestate", "baggage"} {
		if v, ok := s.downstream[k]; ok {
			t.Errorf("tracing off: %s would go downstream: %q", k, v)
		}
	}
	if baggage.FromContext(s.ctx).Len() != 0 {
		t.Error("the client's baggage reached the handler")
	}
	assertNoTraceFields(t, logLines(t, &logs))
}

// Without client headers nothing changes: a new sampled root span, no link.
func TestEdgeNoClientHeaders(t *testing.T) {
	withPropagator(t)
	recorder := tracetest.NewSpanRecorder()
	oldTP := otel.GetTracerProvider()
	otel.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSampler(newSampler()), sdktrace.WithSpanProcessor(recorder)))
	t.Cleanup(func() { otel.SetTracerProvider(oldTP) })

	var logs bytes.Buffer
	h, _ := edgeChain(t, &logs)
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/product/OLJCESPC7Z", nil))
	spans := recorder.Ended()
	if len(spans) != 1 || !spans[0].SpanContext().IsSampled() || len(spans[0].Links()) != 0 || spans[0].Parent().IsValid() {
		t.Fatalf("want one sampled root span without links: %+v", spans)
	}
}
