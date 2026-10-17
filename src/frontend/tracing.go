package main

// OpenTelemetry tracing (ADR 0010), started only with ENABLE_TRACING=1. The same setup is in
// checkoutservice and productcatalogservice:
//   - service name and resource attributes from OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES
//     (set by the Helm chart), with the service's own name as the fallback;
//   - ParentBased(AlwaysSample): follow the caller's sampling decision, sample new root spans
//     (the collector's tail sampling decides what is kept);
//   - W3C TraceContext + Baggage propagation;
//   - the exporter's own connection to the collector has NO otelgrpc interceptor: with one, each
//     export would be traced, that span exported, traced again, and so on;
//   - nothing waits on the collector: the dial is lazy, spans are exported in the background
//     and dropped when the collector is unreachable.

import (
	"context"
	"net/http"

	"github.com/gorilla/mux"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.17.0"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func newPropagator() propagation.TextMapPropagator {
	return propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{})
}

func newSampler() sdktrace.Sampler {
	return sdktrace.ParentBased(sdktrace.AlwaysSample())
}

// newTracingResource: OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES win over the default name.
func newTracingResource(ctx context.Context, defaultName string) (*resource.Resource, error) {
	return resource.New(ctx,
		resource.WithAttributes(semconv.ServiceName(defaultName)),
		resource.WithFromEnv(),
		resource.WithTelemetrySDK(),
	)
}

// dialCollector opens the exporter's connection: plain gRPC, no tracing interceptor, no TLS
// (inside the cluster), not blocking (it connects in the background).
func dialCollector(addr string) (*grpc.ClientConn, error) {
	return grpc.Dial(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
}

// startTracing sets the global tracer provider. A resource error (a malformed
// OTEL_RESOURCE_ATTRIBUTES) is returned with a usable provider.
func startTracing(ctx context.Context, defaultName, collectorAddr string) (*sdktrace.TracerProvider, error) {
	conn, err := dialCollector(collectorAddr)
	if err != nil {
		return nil, err
	}
	exporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithGRPCConn(conn))
	if err != nil {
		return nil, err
	}
	res, resErr := newTracingResource(ctx, defaultName)
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithSampler(newSampler()),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	return tp, resErr
}

// tracedHandler wraps the router for tracing:
//   - drops X-Forwarded-For before otelhttp, which would copy the shopper's IP into
//     http.client_ip (nothing else in the frontend reads it);
//   - names each server span after the method and the route template, "GET /product/{id}",
//     never the raw path (IDs) or the query string; "GET" alone when no route matches.
func tracedHandler(router *mux.Router, next http.Handler) http.Handler {
	named := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if span := trace.SpanFromContext(r.Context()); span.IsRecording() {
			var match mux.RouteMatch
			if router.Match(r, &match) && match.Route != nil {
				if tmpl, err := match.Route.GetPathTemplate(); err == nil {
					span.SetName(r.Method + " " + tmpl)
					span.SetAttributes(semconv.HTTPRoute(tmpl))
				}
			}
		}
		next.ServeHTTP(w, r)
	})
	traced := otelhttp.NewHandler(named, "frontend",
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string { return r.Method }))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Header.Del("X-Forwarded-For")
		traced.ServeHTTP(w, r)
	})
}
