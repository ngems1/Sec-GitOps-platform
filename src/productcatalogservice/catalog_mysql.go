// Week 3: the products table in RDS MySQL (db/migrations), and wiring from env vars.
//
// Same connection setup as checkoutservice: TLS verified against the RDS CA bundle
// in the image, password read from Secrets Manager (managed and rotated by RDS)
// through EKS Pod Identity (role "<env>-productcatalogservice").
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/go-sql-driver/mysql"
	"github.com/golang/protobuf/jsonpb"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/productcatalogservice/genproto"
)

const (
	rdsCABundle         = "/etc/ssl/rds/global-bundle.pem"
	secretCacheTTL      = 10 * time.Minute
	defaultCatalogTTL   = 5 * time.Minute
	catalogStatsEvery   = time.Minute
	productsSelectQuery = `SELECT id, name, description, picture, price_currency, price_units, price_nanos, categories
	                         FROM products ORDER BY id`
)

type mysqlProducts struct {
	db *sql.DB
}

func (m *mysqlProducts) LoadProducts(ctx context.Context) ([]*pb.Product, error) {
	rows, err := m.db.QueryContext(ctx, productsSelectQuery)
	if err != nil {
		return nil, fmt.Errorf("query products: %w", err)
	}
	defer rows.Close()

	var ps []*pb.Product
	for rows.Next() {
		var (
			id, name, description, picture, currency, categories string
			units                                                int64
			nanos                                                int32
		)
		if err := rows.Scan(&id, &name, &description, &picture, &currency, &units, &nanos, &categories); err != nil {
			return nil, fmt.Errorf("read product row: %w", err)
		}
		ps = append(ps, &pb.Product{
			Id:          id,
			Name:        name,
			Description: description,
			Picture:     picture,
			PriceUsd:    &pb.Money{CurrencyCode: currency, Units: units, Nanos: nanos},
			Categories:  splitCategories(categories),
		})
	}
	return ps, rows.Err()
}

func splitCategories(s string) []string {
	var out []string
	for _, c := range strings.Split(s, ",") {
		if c = strings.TrimSpace(c); c != "" {
			out = append(out, c)
		}
	}
	return out
}

// newCatalogLoaderFromEnv returns nil (products.json only, as before) unless
// DB_SECRET_ARN is set. REDIS_ADDR adds the cache; CATALOG_CACHE_TTL sets its expiry.
func newCatalogLoaderFromEnv(ctx context.Context, fallback func() []*pb.Product) (*catalogLoader, error) {
	secretARN := os.Getenv("DB_SECRET_ARN")
	if secretARN == "" {
		return nil, nil
	}
	host, name := os.Getenv("DB_HOST"), os.Getenv("DB_NAME")
	if host == "" || name == "" {
		return nil, fmt.Errorf("DB_HOST and DB_NAME must be set with DB_SECRET_ARN")
	}
	port := os.Getenv("DB_PORT")
	if port == "" {
		port = "3306"
	}

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
	cfg.Timeout = 3 * time.Second
	cfg.ReadTimeout = 5 * time.Second
	cfg.WriteTimeout = 5 * time.Second
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
	// Connections are opened on first use: a database that is still starting
	// never blocks the service, requests fall back until it answers.
	db := sql.OpenDB(connector)
	db.SetMaxOpenConns(3)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(5 * time.Minute)

	ttl := defaultCatalogTTL
	if s := os.Getenv("CATALOG_CACHE_TTL"); s != "" {
		if ttl, err = time.ParseDuration(s); err != nil || ttl <= 0 {
			return nil, fmt.Errorf("CATALOG_CACHE_TTL %q: want a duration like 5m", s)
		}
	}

	loader := &catalogLoader{
		source:   &mysqlProducts{db: db},
		ttl:      ttl,
		fallback: fallback,
		encode:   encodeProducts,
		decode:   decodeProducts,
	}
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache := newRedisCache(addr)
		cache.useTLS = strings.EqualFold(os.Getenv("REDIS_TLS"), "true")
		cache.password = os.Getenv("REDIS_PASSWORD")
		loader.cache = cache
	}
	return loader, nil
}

// rdsTLS verifies the server certificate and host name against the RDS CA bundle.
func rdsTLS(host string) (*tls.Config, error) {
	pem, err := os.ReadFile(rdsCABundle)
	if err != nil {
		return nil, fmt.Errorf("RDS CA bundle: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("RDS CA bundle: no certificates in %s", rdsCABundle)
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

// The cache holds the same JSON format as products.json.
func encodeProducts(ps []*pb.Product) ([]byte, error) {
	s, err := (&jsonpb.Marshaler{}).MarshalToString(&pb.ListProductsResponse{Products: ps})
	return []byte(s), err
}

func decodeProducts(data []byte) ([]*pb.Product, error) {
	var resp pb.ListProductsResponse
	if err := jsonpb.Unmarshal(bytes.NewReader(data), &resp); err != nil {
		return nil, err
	}
	return resp.Products, nil
}
