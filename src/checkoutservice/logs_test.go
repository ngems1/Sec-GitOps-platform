package main

import (
	"bytes"
	"context"
	"net"
	"strings"
	"testing"

	"github.com/sirupsen/logrus"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/checkoutservice/genproto"
)

// emptyCart is a cartservice that always returns an empty cart.
type emptyCart struct{}

func (emptyCart) GetCart(context.Context, *pb.GetCartRequest) (*pb.Cart, error) {
	return &pb.Cart{}, nil
}

func (emptyCart) AddItem(context.Context, *pb.AddItemRequest) (*pb.Empty, error) {
	return &pb.Empty{}, nil
}

func (emptyCart) EmptyCart(context.Context, *pb.EmptyCartRequest) (*pb.Empty, error) {
	return &pb.Empty{}, nil
}

// PlaceOrder logs the order ID, never the user ID (the shopper's session ID) or the email
// (ADR 0011). The empty-cart path is the one a test can reach without the other services.
func TestPlaceOrderLogsNoPersonalData(t *testing.T) {
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	pb.RegisterCartServiceServer(srv, emptyCart{})
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	conn, err := grpc.Dial("bufnet", grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return lis.Dial() }))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })

	var buf bytes.Buffer
	oldOut, oldLevel := log.Out, log.Level
	log.Out, log.Level = &buf, logrus.DebugLevel
	t.Cleanup(func() { log.Out, log.Level = oldOut, oldLevel })

	cs := &checkoutService{cartSvcConn: conn}
	_, err = cs.PlaceOrder(context.Background(), &pb.PlaceOrderRequest{
		UserId: "session-5f1c2a", UserCurrency: "USD", Email: "jane@example.com",
		Address:    &pb.Address{StreetAddress: "1600 Amphitheatre Parkway", City: "Mountain View"},
		CreditCard: &pb.CreditCardInfo{CreditCardNumber: "4432801561520454", CreditCardCvv: 672},
	})
	if err == nil {
		t.Fatal("an empty cart must be rejected")
	}
	logs := buf.String()
	if !strings.Contains(logs, `"orderId"`) || !strings.Contains(logs, "cart is empty") {
		t.Fatalf("expected the order ID and the rejection in the logs:\n%s", logs)
	}
	for _, secret := range []string{"session-5f1c2a", "jane", "example.com", "Amphitheatre", "4432801561520454", "0454"} {
		if strings.Contains(logs, secret) {
			t.Errorf("logs contain %q:\n%s", secret, logs)
		}
	}
}
