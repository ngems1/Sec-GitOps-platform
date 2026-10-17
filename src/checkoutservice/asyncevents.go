package main

// Trace context across EventBridge and SQS (ADR 0010, step 5). EventBridge has no message
// attributes, so the W3C context travels in the event detail, in a "_trace" field:
//
//	{"version": "1", "orderId": "...", ..., "_trace": {"traceparent": "00-...-01", "tracestate": "..."}}
//
// The consumers (inventoryservice, then the order-status Lambda and emailservice) take it out
// before reading the event, and handle events without it as before. It is added only while the
// current span is recording (tracing on): with tracing off (prod) the events are unchanged.

import (
	"context"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

// traceCarrier returns the W3C trace context of ctx for the event's "_trace" field (traceparent
// and tracestate only, never baggage), or nil when no span is recording.
func traceCarrier(ctx context.Context) map[string]string {
	if !trace.SpanFromContext(ctx).IsRecording() {
		return nil
	}
	carrier := propagation.MapCarrier{}
	propagation.TraceContext{}.Inject(ctx, carrier)
	if carrier["traceparent"] == "" {
		return nil
	}
	out := map[string]string{"traceparent": carrier["traceparent"]}
	if ts := carrier["tracestate"]; ts != "" {
		out["tracestate"] = ts
	}
	return out
}

// startPublishSpan opens the PRODUCER span around PutEvents. Its attributes name the bus and the
// order, never the shopper (no email address, name or card).
func startPublishSpan(ctx context.Context, bus, orderID string) (context.Context, trace.Span) {
	return otel.Tracer("checkoutservice").Start(ctx, "publish "+orderCreatedType,
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "aws_eventbridge"),
			attribute.String("messaging.operation", "publish"),
			attribute.String("messaging.destination.name", bus),
			attribute.String("boutique.order_id", orderID),
		))
}
