package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/baggage"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/checkoutservice/genproto"
)

func testEvent() orderCreated {
	return newOrderCreated(&pb.OrderResult{OrderId: "o-1", ShippingTrackingId: "TRK-1"},
		"jane@example.com", &pb.Money{CurrencyCode: "USD", Units: 1})
}

// Tracing off (prod): no "_trace" field, the event is exactly as before.
func TestNoTraceFieldWhenTracingIsOff(t *testing.T) {
	ctx, span := startPublishSpan(context.Background(), "bus", "o-1") // global no-op provider
	defer span.End()
	ev := testEvent()
	ev.Trace = traceCarrier(ctx)
	out, _ := json.Marshal(ev)
	if strings.Contains(string(out), "_trace") {
		t.Fatalf("tracing off but the event has a trace field: %s", out)
	}
}

// Tracing on: the event carries the PRODUCER span's context (traceparent only, no baggage), and
// the span names the order, never the shopper.
func TestTraceFieldAndProducerSpan(t *testing.T) {
	recorder := tracetest.NewSpanRecorder()
	old := otel.GetTracerProvider()
	otel.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder)))
	t.Cleanup(func() { otel.SetTracerProvider(old) })

	member, _ := baggage.NewMember("session", "secret-session")
	bag, _ := baggage.New(member)
	ctx := baggage.ContextWithBaggage(context.Background(), bag)
	ctx, span := startPublishSpan(ctx, "week3-boutique-dev-events", "o-1")
	ev := testEvent()
	ev.Trace = traceCarrier(ctx)
	span.End()

	out, _ := json.Marshal(ev)
	var decoded map[string]any
	_ = json.Unmarshal(out, &decoded)
	field, ok := decoded["_trace"].(map[string]any)
	if !ok {
		t.Fatalf("no _trace field: %s", out)
	}
	want := span.SpanContext().TraceID().String() + "-" + span.SpanContext().SpanID().String()
	if tp, _ := field["traceparent"].(string); !strings.Contains(tp, want) {
		t.Errorf("traceparent %q does not carry the producer span %s", tp, want)
	}
	if strings.Contains(string(out), "secret-session") || field["baggage"] != nil {
		t.Errorf("baggage leaked into the event: %s", out)
	}
	// The consumers still read the same keys.
	for _, k := range []string{"version", "orderId", "email", "items", "total", "shippingTrackingId"} {
		if _, ok := decoded[k]; !ok {
			t.Errorf("event lost %q", k)
		}
	}

	ended := recorder.Ended()
	if len(ended) != 1 || ended[0].Name() != "publish OrderCreated" || ended[0].SpanKind() != trace.SpanKindProducer {
		t.Fatalf("producer span: %+v", ended)
	}
	for _, kv := range ended[0].Attributes() {
		if strings.Contains(kv.Value.Emit(), "jane") || strings.Contains(kv.Value.Emit(), "@") {
			t.Errorf("attribute %s leaks the shopper: %q", kv.Key, kv.Value.Emit())
		}
	}
}
