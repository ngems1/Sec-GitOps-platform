// Week 3: the "Order Service" part of checkout.
//
// After a successful payment and shipment, PlaceOrder:
//  1. saves the order in RDS MySQL with status PENDING (table "orders", db/migrations)
//  2. publishes OrderCreated to the environment's EventBridge bus
//
// inventoryservice then reserves the stock and the order-status Lambda moves the
// order to CONFIRMED or FAILED. Everything here is off when EVENT_BUS_NAME or
// DB_SECRET_ARN is unset (local Docker Compose), so the shop works as before.
//
// AWS access: EKS Pod Identity (role "<env>-checkoutservice"): secretsmanager
// GetSecretValue on the database secret, kms:Decrypt, events:PutEvents on the bus.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/eventbridge"
	ebtypes "github.com/aws/aws-sdk-go-v2/service/eventbridge/types"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/go-sql-driver/mysql"
	"go.opentelemetry.io/otel/codes"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/checkoutservice/genproto"
)

const (
	orderEventSource   = "boutique.checkout"
	orderCreatedType   = "OrderCreated"
	orderSchemaVersion = "1" // same as inventoryservice and the order-status Lambda
	rdsCABundle        = "/etc/ssl/rds/global-bundle.pem"
	secretCacheTTL     = 10 * time.Minute
)

// orderLine and orderTotal are the JSON shapes shared with the consumers.
type orderLine struct {
	ProductID string `json:"productId"`
	Quantity  int32  `json:"quantity"`
}

type orderTotal struct {
	CurrencyCode string `json:"currencyCode"`
	Units        int64  `json:"units"`
	Nanos        int32  `json:"nanos"`
}

type orderCreated struct {
	Version            string      `json:"version"`
	OrderID            string      `json:"orderId"`
	Email              string      `json:"email"`
	Items              []orderLine `json:"items"`
	Total              orderTotal  `json:"total"`
	ShippingTrackingID string      `json:"shippingTrackingId"`
	// W3C trace context for the consumers (asyncevents.go); absent while tracing is off.
	Trace map[string]string `json:"_trace,omitempty"`
}

// orderLines turns the order items into {productId, quantity} lines.
func orderLines(items []*pb.OrderItem) []orderLine {
	lines := make([]orderLine, 0, len(items))
	for _, it := range items {
		if it.GetItem() == nil {
			continue
		}
		lines = append(lines, orderLine{ProductID: it.GetItem().GetProductId(), Quantity: it.GetItem().GetQuantity()})
	}
	return lines
}

// newOrderCreated builds the OrderCreated event detail.
func newOrderCreated(order *pb.OrderResult, email string, total *pb.Money) orderCreated {
	return orderCreated{
		Version:            orderSchemaVersion,
		OrderID:            order.GetOrderId(),
		Email:              email,
		Items:              orderLines(order.GetItems()),
		Total:              orderTotal{CurrencyCode: total.GetCurrencyCode(), Units: total.GetUnits(), Nanos: total.GetNanos()},
		ShippingTrackingID: order.GetShippingTrackingId(),
	}
}

type orderStore struct {
	db     *sql.DB
	events *eventbridge.Client
	bus    string
}

// newOrderStore returns (nil, nil) when the AWS settings are absent: feature off.
func newOrderStore(ctx context.Context) (*orderStore, error) {
	bus, secretARN := os.Getenv("EVENT_BUS_NAME"), os.Getenv("DB_SECRET_ARN")
	if bus == "" || secretARN == "" {
		return nil, nil
	}
	host, name := os.Getenv("DB_HOST"), os.Getenv("DB_NAME")
	if host == "" || name == "" {
		return nil, errors.New("DB_HOST and DB_NAME must be set with DB_SECRET_ARN")
	}
	port := os.Getenv("DB_PORT")
	if port == "" {
		port = "3306"
	}

	// Region from AWS_REGION, credentials from EKS Pod Identity.
	awsCfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("aws config: %w", err)
	}

	tlsCfg, err := rdsTLS(host)
	if err != nil {
		return nil, err
	}

	cfg := mysql.NewConfig()
	cfg.Net = "tcp"
	cfg.Addr = host + ":" + port
	cfg.DBName = name
	cfg.TLS = tlsCfg
	cfg.Timeout = 5 * time.Second
	cfg.ReadTimeout = 10 * time.Second
	cfg.WriteTimeout = 10 * time.Second
	cfg.ParseTime = true

	// The database password is managed (and rotated) by RDS in Secrets Manager:
	// it is read for every new connection, through a short cache.
	secrets := &dbSecret{client: secretsmanager.NewFromConfig(awsCfg), arn: secretARN}
	if err := cfg.Apply(mysql.BeforeConnect(func(ctx context.Context, c *mysql.Config) error {
		user, pass, err := secrets.get(ctx)
		if err != nil {
			return err
		}
		c.User, c.Passwd = user, pass
		return nil
	})); err != nil {
		return nil, fmt.Errorf("mysql config: %w", err)
	}

	connector, err := mysql.NewConnector(cfg)
	if err != nil {
		return nil, fmt.Errorf("mysql connector: %w", err)
	}
	db := sql.OpenDB(connector)
	db.SetMaxOpenConns(5)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)

	pingCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		db.Close()
		return nil, fmt.Errorf("database %s: %w", cfg.Addr, err)
	}
	return &orderStore{db: db, events: eventbridge.NewFromConfig(awsCfg), bus: bus}, nil
}

// rdsTLS returns a TLS config that verifies the RDS server certificate and host
// name against the RDS CA bundle shipped in the image. A missing or unreadable
// bundle is an error: falling back to the system roots can never work with RDS
// and only hides the real cause ("certificate signed by unknown authority").
func rdsTLS(host string) (*tls.Config, error) {
	path := os.Getenv("RDS_CA_BUNDLE")
	if path == "" {
		path = rdsCABundle
	}
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("RDS CA bundle: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("RDS CA bundle: no certificates in %s", path)
	}
	return &tls.Config{ServerName: host, RootCAs: pool, MinVersion: tls.VersionTLS12}, nil
}

// dbSecret reads {"username": ..., "password": ...} and caches it for a few minutes.
type dbSecret struct {
	client  *secretsmanager.Client
	arn     string
	mu      sync.Mutex
	user    string
	pass    string
	fetched time.Time
}

func (s *dbSecret) get(ctx context.Context) (string, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.user != "" && time.Since(s.fetched) < secretCacheTTL {
		return s.user, s.pass, nil
	}
	out, err := s.client.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{SecretId: aws.String(s.arn)})
	if err != nil {
		return "", "", fmt.Errorf("read database secret: %w", err)
	}
	var v struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.Unmarshal([]byte(aws.ToString(out.SecretString)), &v); err != nil {
		return "", "", fmt.Errorf("database secret is not JSON: %w", err)
	}
	s.user, s.pass, s.fetched = v.Username, v.Password, time.Now()
	return s.user, s.pass, nil
}

// record saves the order as PENDING, then publishes OrderCreated.
// Saving first means the order-status Lambda always finds the row to update.
func (s *orderStore) record(ctx context.Context, order *pb.OrderResult, email string, total *pb.Money) error {
	event := newOrderCreated(order, email, total)
	items, err := json.Marshal(event.Items)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	// INSERT IGNORE: a retried request with the same order ID never creates a duplicate.
	if _, err := s.db.ExecContext(ctx,
		`INSERT IGNORE INTO orders
		   (order_id, email, status, currency, total_units, total_nanos, items, shipping_tracking_id)
		 VALUES (?, ?, 'PENDING', ?, ?, ?, ?, ?)`,
		event.OrderID, email, event.Total.CurrencyCode, event.Total.Units, event.Total.Nanos,
		string(items), event.ShippingTrackingID); err != nil {
		return fmt.Errorf("save order: %w", err)
	}

	// PRODUCER span around the publish; its context goes into the event (asyncevents.go).
	ctx, span := startPublishSpan(ctx, s.bus, event.OrderID)
	defer span.End()
	event.Trace = traceCarrier(ctx)
	detail, err := json.Marshal(event)
	if err != nil {
		return err
	}
	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		out, err := s.events.PutEvents(ctx, &eventbridge.PutEventsInput{
			Entries: []ebtypes.PutEventsRequestEntry{{
				EventBusName: aws.String(s.bus),
				Source:       aws.String(orderEventSource),
				DetailType:   aws.String(orderCreatedType),
				Detail:       aws.String(string(detail)),
			}},
		})
		switch {
		case err != nil:
			lastErr = err
		case out.FailedEntryCount > 0:
			lastErr = fmt.Errorf("event rejected: %s %s",
				aws.ToString(out.Entries[0].ErrorCode), aws.ToString(out.Entries[0].ErrorMessage))
		default:
			log.WithContext(ctx).WithField("orderId", event.OrderID).Info("order saved (PENDING) and OrderCreated published")
			return nil
		}
		time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
	}
	span.SetStatus(codes.Error, "OrderCreated not published")
	return fmt.Errorf("publish OrderCreated: %w", lastErr)
}
