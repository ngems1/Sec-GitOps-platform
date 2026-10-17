package main

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	semconv "go.opentelemetry.io/otel/semconv/v1.17.0"
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
	tp, err := startTracing(context.Background(), "productcatalogservice", "127.0.0.1:1") // nothing listens there
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
	t.Setenv("OTEL_SERVICE_NAME", "productcatalogservice-from-env")
	t.Setenv("OTEL_RESOURCE_ATTRIBUTES", "deployment.environment=dev,service.namespace=boutique")
	res, err := newTracingResource(context.Background(), "productcatalogservice")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, kv := range res.Attributes() {
		got[string(kv.Key)] = kv.Value.Emit()
	}
	if got["service.name"] != "productcatalogservice-from-env" || got["deployment.environment"] != "dev" || got["service.namespace"] != "boutique" {
		t.Errorf("resource = %v", got)
	}

	t.Setenv("OTEL_SERVICE_NAME", "")
	t.Setenv("OTEL_RESOURCE_ATTRIBUTES", "")
	res, _ = newTracingResource(context.Background(), "productcatalogservice")
	for _, kv := range res.Attributes() {
		if kv.Key == semconv.ServiceNameKey && kv.Value.Emit() != "productcatalogservice" {
			t.Errorf("default service.name = %q", kv.Value.Emit())
		}
	}
}
