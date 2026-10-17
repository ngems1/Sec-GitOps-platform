package main

// Trace context in the JSON logs (ADR 0011, step 6). The same file is in frontend,
// checkoutservice, productcatalogservice and shippingservice.
//
// A log entry written with a context (log.WithContext(ctx)) gets the fields of the span in
// that context:
//
//	"trace_id": "4bf92f3577b34da6a3ce929d0e0e4736", "span_id": "00f067aa0ba902b7", "trace_sampled": true
//
// lower-case hex, as in a W3C traceparent; CloudWatch Logs Insights and Grafana find a trace's
// lines by trace_id (ADR 0011). Nothing is added without a context, without a valid span, or
// while tracing is off (ENABLE_TRACING unset, the prod default): the W3C propagator also runs
// then, so a traceparent sent by a client would otherwise put an ID of its choosing in our logs.

import (
	"github.com/sirupsen/logrus"
	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

type traceLogHook struct{}

func (traceLogHook) Levels() []logrus.Level { return logrus.AllLevels }

func (traceLogHook) Fire(e *logrus.Entry) error {
	if e.Context == nil {
		return nil
	}
	if _, on := otel.GetTracerProvider().(*sdktrace.TracerProvider); !on {
		return nil // tracing off: no IDs, whatever the request carried
	}
	sc := trace.SpanContextFromContext(e.Context)
	if !sc.IsValid() {
		return nil
	}
	e.Data["trace_id"] = sc.TraceID().String()
	e.Data["span_id"] = sc.SpanID().String()
	e.Data["trace_sampled"] = sc.IsSampled()
	return nil
}
