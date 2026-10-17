package main

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/sirupsen/logrus"
)

// The loader's request-time lines (a failed MySQL load here) carry the ListProducts span's IDs
// (ADR 0011).
func TestLoaderLogsCarryTraceIDs(t *testing.T) {
	tracer := withTracing(t)
	var buf bytes.Buffer
	oldOut, oldLevel := log.Out, log.Level
	log.Out, log.Level = &buf, logrus.DebugLevel
	t.Cleanup(func() { log.Out, log.Level = oldOut, oldLevel })

	l := newTestLoader(&fakeSource{err: errors.New("db down")}, nil)
	ctx, span := tracer.Start(context.Background(), "hipstershop.ProductCatalogService/ListProducts")
	if ps := l.products(ctx); len(ps) == 0 {
		t.Fatal("the fallback catalog should be served")
	}
	span.End()
	lines := logLines(t, &buf)
	if len(lines) != 2 { // MySQL load failed, serving the built-in products.json
		t.Fatalf("want 2 lines, got %d: %v", len(lines), lines)
	}
	assertTraceFields(t, lines, span.SpanContext())
}
