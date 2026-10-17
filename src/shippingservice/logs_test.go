package main

import (
	"bytes"
	"context"
	"testing"

	"github.com/sirupsen/logrus"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/shippingservice/genproto"
)

// GetQuote's lines carry the gRPC server span's IDs (ADR 0011).
func TestGetQuoteLogsCarryTraceIDs(t *testing.T) {
	tracer := withTracing(t)
	var buf bytes.Buffer
	oldOut, oldLevel := log.Out, log.Level
	log.Out, log.Level = &buf, logrus.DebugLevel
	t.Cleanup(func() { log.Out, log.Level = oldOut, oldLevel })

	ctx, span := tracer.Start(context.Background(), "hipstershop.ShippingService/GetQuote")
	if _, err := (&server{}).GetQuote(ctx, &pb.GetQuoteRequest{}); err != nil {
		t.Fatal(err)
	}
	span.End()
	lines := logLines(t, &buf)
	if len(lines) != 2 { // received request, completed request
		t.Fatalf("want 2 lines, got %d: %v", len(lines), lines)
	}
	assertTraceFields(t, lines, span.SpanContext())
}
