package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/mux"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	semconv "go.opentelemetry.io/otel/semconv/v1.17.0"
	"go.opentelemetry.io/otel/trace"
	coltracepb "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	"google.golang.org/grpc"
)

// fakeCollector accepts OTLP trace exports and counts them.
type fakeCollector struct {
	coltracepb.UnimplementedTraceServiceServer
	exports chan struct{}
}

func (f *fakeCollector) Export(context.Context, *coltracepb.ExportTraceServiceRequest) (*coltracepb.ExportTraceServiceResponse, error) {
	f.exports <- struct{}{}
	return &coltracepb.ExportTraceServiceResponse{}, nil
}

func startFakeCollector(t *testing.T) (string, *fakeCollector) {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeCollector{exports: make(chan struct{}, 10)}
	srv := grpc.NewServer()
	coltracepb.RegisterTraceServiceServer(srv, f)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	return lis.Addr().String(), f
}

// The exporter's connection must not trace its own Export calls (self-tracing loop).
func TestExporterConnectionIsNotTraced(t *testing.T) {
	addr, collector := startFakeCollector(t)
	recorder := tracetest.NewSpanRecorder()
	old := otel.GetTracerProvider()
	otel.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder)))
	t.Cleanup(func() { otel.SetTracerProvider(old) })

	conn, err := dialCollector(addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	exporter, err := otlptracegrpc.New(context.Background(), otlptracegrpc.WithGRPCConn(conn))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stub := tracetest.SpanStub{Name: "test"}
	if err := exporter.ExportSpans(ctx, []sdktrace.ReadOnlySpan{stub.Snapshot()}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-collector.exports:
	case <-ctx.Done():
		t.Fatal("the fake collector got no export")
	}
	for _, s := range recorder.Ended() {
		t.Errorf("the export created a span %q: the collector connection is traced", s.Name())
	}
}

func TestCollectorUnreachableDoesNotBlock(t *testing.T) {
	start := time.Now()
	tp, err := startTracing(context.Background(), "frontend", "127.0.0.1:1") // nothing listens there
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = tp.Shutdown(ctx)
		otel.SetTracerProvider(sdktrace.NewTracerProvider())
	})
	_, span := otel.Tracer("test").Start(context.Background(), "request")
	span.End()
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("starting tracing and ending a span took %v with no collector", d)
	}
}

func TestSamplerIsParentBased(t *testing.T) {
	if d := newSampler().Description(); !strings.HasPrefix(d, "ParentBased{root:AlwaysOnSampler") {
		t.Errorf("sampler = %s", d)
	}
}

func TestServiceNameFromEnv(t *testing.T) {
	t.Setenv("OTEL_SERVICE_NAME", "frontend-from-env")
	t.Setenv("OTEL_RESOURCE_ATTRIBUTES", "deployment.environment=dev,service.namespace=boutique")
	res, err := newTracingResource(context.Background(), "frontend")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, kv := range res.Attributes() {
		got[string(kv.Key)] = kv.Value.Emit()
	}
	if got["service.name"] != "frontend-from-env" || got["deployment.environment"] != "dev" || got["service.namespace"] != "boutique" {
		t.Errorf("resource = %v", got)
	}

	t.Setenv("OTEL_SERVICE_NAME", "")
	t.Setenv("OTEL_RESOURCE_ATTRIBUTES", "")
	res, _ = newTracingResource(context.Background(), "frontend")
	for _, kv := range res.Attributes() {
		if kv.Key == semconv.ServiceNameKey && kv.Value.Emit() != "frontend" {
			t.Errorf("default service.name = %q", kv.Value.Emit())
		}
	}
}

func TestSpanNamedAfterRoute(t *testing.T) {
	recorder := tracetest.NewSpanRecorder()
	old := otel.GetTracerProvider()
	otel.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder)))
	t.Cleanup(func() { otel.SetTracerProvider(old) })

	r := mux.NewRouter()
	ok := func(w http.ResponseWriter, _ *http.Request) {}
	r.HandleFunc("/product/{id}", ok).Methods(http.MethodGet)
	r.HandleFunc("/assistant", ok).Methods(http.MethodGet, http.MethodPost)
	r.HandleFunc("/_healthz", ok)
	h := tracedHandler(r, r)

	for _, c := range []struct{ method, target, want string }{
		{http.MethodGet, "/product/OLJCESPC7Z?ref=mail&email=jane@example.com", "GET /product/{id}"},
		{http.MethodPost, "/assistant?q=my+card+4111111111111111", "POST /assistant"},
		{http.MethodGet, "/_healthz", "GET /_healthz"},
		{http.MethodGet, "/no/such/page?secret=1", "GET"},
	} {
		req := httptest.NewRequest(c.method, c.target, nil)
		req.Header.Set("X-Forwarded-For", "203.0.113.7")
		h.ServeHTTP(httptest.NewRecorder(), req)
		spans := recorder.Ended()
		s := spans[len(spans)-1]
		if s.Name() != c.want {
			t.Errorf("%s %s: span %q, want %q", c.method, c.target, s.Name(), c.want)
		}
		for _, kv := range s.Attributes() {
			v := kv.Value.Emit()
			for _, secret := range []string{"OLJCESPC7Z", "jane", "4111", "secret", "203.0.113.7", "?"} {
				if strings.Contains(v, secret) {
					t.Errorf("%s %s: attribute %s=%q leaks %q", c.method, c.target, kv.Key, v, secret)
				}
			}
			if kv.Key == semconv.HTTPRouteKey && !strings.HasPrefix(c.want, c.method+" "+v) {
				t.Errorf("%s %s: http.route %q", c.method, c.target, v)
			}
		}
	}
}

// The call to the shopping assistant carries the trace (otelhttp transport): one trace covers
// frontend -> assistant. The session's hash travels as X-Session-Id but is never a span attribute.
func TestAssistantCallCarriesTheTrace(t *testing.T) {
	recorder := tracetest.NewSpanRecorder()
	oldTP, oldProp := otel.GetTracerProvider(), otel.GetTextMapPropagator()
	otel.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder)))
	otel.SetTextMapPropagator(newPropagator())
	t.Cleanup(func() { otel.SetTracerProvider(oldTP); otel.SetTextMapPropagator(oldProp) })

	srv, f := fakeAssistant(t, http.StatusOK, `{"outcome":"answered","answer":"ok","products":[]}`)
	withAssistant(t, srv.URL)
	ctx, parent := otel.Tracer("test").Start(context.Background(), "POST /assistant")
	askAssistant(ctx, "a question", "EUR", "session-123")
	parent.End()

	_, headers, _ := f.last()
	want := parent.SpanContext().TraceID().String()
	if tp := headers.Get("Traceparent"); !strings.Contains(tp, want) {
		t.Fatalf("traceparent %q does not carry trace %s", tp, want)
	}
	var client bool
	for _, s := range recorder.Ended() {
		if s.SpanKind() == trace.SpanKindClient && s.Parent().TraceID().String() == want {
			client = true
		}
		for _, kv := range s.Attributes() {
			if v := kv.Value.Emit(); strings.Contains(v, hashedSession("session-123")) || strings.Contains(v, "a question") {
				t.Errorf("span %q attribute %s leaks %q", s.Name(), kv.Key, v)
			}
		}
	}
	if !client {
		t.Error("no client span for the assistant call")
	}
}
