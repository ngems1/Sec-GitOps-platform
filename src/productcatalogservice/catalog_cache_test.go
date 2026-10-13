package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeRedis is a tiny in-memory Redis speaking RESP, for GET and SET ... EX,
// optionally behind TLS and requiring AUTH <password> like ElastiCache.
type fakeRedis struct {
	ln       net.Listener
	password string // "" = no auth required
	mu       sync.Mutex
	data     map[string]string
	ttls     map[string]string
}

func startFakeRedis(t *testing.T) *fakeRedis {
	return startFakeRedisWith(t, "", nil)
}

// startFakeRedisWith starts a fake that requires AUTH when password is set and
// speaks TLS when serverTLS is set.
func startFakeRedisWith(t *testing.T, password string, serverTLS *tls.Config) *fakeRedis {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	if serverTLS != nil {
		ln = tls.NewListener(ln, serverTLS)
	}
	f := &fakeRedis{ln: ln, password: password, data: map[string]string{}, ttls: map[string]string{}}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go f.serve(conn)
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return f
}

func (f *fakeRedis) serve(conn net.Conn) {
	defer conn.Close()
	rd := bufio.NewReader(conn)
	authed := f.password == ""
	for {
		line, err := rd.ReadString('\n')
		if err != nil {
			return
		}
		n, _ := strconv.Atoi(strings.TrimSpace(line[1:]))
		args := make([]string, n)
		for i := range args {
			if _, err := rd.ReadString('\n'); err != nil { // $len
				return
			}
			v, err := rd.ReadString('\n')
			if err != nil {
				return
			}
			args[i] = strings.TrimSuffix(v, "\r\n")
		}
		if strings.ToUpper(args[0]) == "AUTH" {
			if f.password != "" && len(args) == 2 && args[1] == f.password {
				authed = true
				conn.Write([]byte("+OK\r\n"))
			} else {
				conn.Write([]byte("-WRONGPASS invalid username-password pair or user is disabled.\r\n"))
			}
			continue
		}
		if !authed {
			conn.Write([]byte("-NOAUTH Authentication required.\r\n"))
			continue
		}
		f.mu.Lock()
		switch strings.ToUpper(args[0]) {
		case "GET":
			if v, ok := f.data[args[1]]; ok {
				conn.Write([]byte("$" + strconv.Itoa(len(v)) + "\r\n" + v + "\r\n"))
			} else {
				conn.Write([]byte("$-1\r\n"))
			}
		case "SET":
			f.data[args[1]] = args[2]
			if len(args) >= 5 {
				f.ttls[args[1]] = args[4]
			}
			conn.Write([]byte("+OK\r\n"))
		default:
			conn.Write([]byte("-ERR unknown command\r\n"))
		}
		f.mu.Unlock()
	}
}

func TestRedisGetMissingKey(t *testing.T) {
	f := startFakeRedis(t)
	c := newRedisCache(f.ln.Addr().String())
	_, found, err := c.Get(context.Background(), "nope")
	if err != nil || found {
		t.Fatalf("got found=%v err=%v, want a clean miss", found, err)
	}
}

func TestRedisSetThenGet(t *testing.T) {
	f := startFakeRedis(t)
	c := newRedisCache(f.ln.Addr().String())
	ctx := context.Background()
	value := `{"products":[{"id":"A","name":"Line\r\nbreak"}]}` // binary-safe
	if err := c.Set(ctx, "k", []byte(value), 5*time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := f.ttls["k"]; got != "300" {
		t.Errorf("TTL sent = %q, want 300 seconds", got)
	}
	got, found, err := c.Get(ctx, "k")
	if err != nil || !found || string(got) != value {
		t.Fatalf("got %q found=%v err=%v", got, found, err)
	}
}

func TestRedisErrorReplyKeepsConnection(t *testing.T) {
	f := startFakeRedis(t)
	c := newRedisCache(f.ln.Addr().String())
	if _, err := c.do(context.Background(), "BOGUS"); err == nil {
		t.Fatal("want an error reply")
	}
	if c.conn == nil {
		t.Fatal("an error reply from Redis should not drop the connection")
	}
}

func TestRedisUnreachable(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	ln.Close() // nothing listens there now
	c := newRedisCache(addr)
	if _, _, err := c.Get(context.Background(), "k"); err == nil {
		t.Fatal("want a connection error")
	}
}

func TestEncodeCommand(t *testing.T) {
	got := string(encodeCommand([]string{"GET", "key"}))
	if want := "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// selfSignedTLS returns a server TLS config for 127.0.0.1 and a client config
// that trusts it (the role ElastiCache's Amazon-issued certificate plays in AWS).
func selfSignedTLS(t *testing.T) (server, client *tls.Config) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "127.0.0.1"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	server = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
	client = &tls.Config{RootCAs: pool, ServerName: "127.0.0.1", MinVersion: tls.VersionTLS12}
	return server, client
}

func TestRedisAuthSentOnConnect(t *testing.T) {
	f := startFakeRedisWith(t, "s3cret", nil)
	c := newRedisCache(f.ln.Addr().String())
	c.password = "s3cret"
	ctx := context.Background()
	if err := c.Set(ctx, "k", []byte("v"), time.Minute); err != nil {
		t.Fatalf("set with the right token: %v", err)
	}
	if got, found, err := c.Get(ctx, "k"); err != nil || !found || string(got) != "v" {
		t.Fatalf("got %q found=%v err=%v", got, found, err)
	}
}

func TestRedisWrongPasswordFails(t *testing.T) {
	f := startFakeRedisWith(t, "s3cret", nil)
	c := newRedisCache(f.ln.Addr().String())
	c.password = "the-dev-token"
	_, _, err := c.Get(context.Background(), "k")
	if err == nil {
		t.Fatal("want an auth error with a wrong token")
	}
	if strings.Contains(err.Error(), "the-dev-token") {
		t.Fatalf("the error leaks the token: %v", err)
	}
	if c.conn != nil {
		t.Fatal("a failed AUTH should drop the connection")
	}
}

func TestRedisWithoutTokenIsRejected(t *testing.T) {
	f := startFakeRedisWith(t, "s3cret", nil)
	c := newRedisCache(f.ln.Addr().String()) // no password: like a pod without the Secret
	if _, _, err := c.Get(context.Background(), "k"); err == nil || !strings.Contains(err.Error(), "NOAUTH") {
		t.Fatalf("got err=%v, want NOAUTH", err)
	}
}

func TestRedisTLSAndAuth(t *testing.T) {
	serverTLS, clientTLS := selfSignedTLS(t)
	f := startFakeRedisWith(t, "s3cret", serverTLS)
	c := newRedisCache(f.ln.Addr().String())
	c.useTLS, c.tlsConfig, c.password = true, clientTLS, "s3cret"
	ctx := context.Background()
	if err := c.Set(ctx, "k", []byte("over TLS"), time.Minute); err != nil {
		t.Fatalf("set over TLS: %v", err)
	}
	if got, found, err := c.Get(ctx, "k"); err != nil || !found || string(got) != "over TLS" {
		t.Fatalf("got %q found=%v err=%v", got, found, err)
	}
}

func TestRedisTLSRejectsUntrustedCertificate(t *testing.T) {
	serverTLS, _ := selfSignedTLS(t)
	f := startFakeRedisWith(t, "", serverTLS)
	c := newRedisCache(f.ln.Addr().String())
	c.useTLS = true // system CAs only: the self-signed certificate must be refused
	if _, _, err := c.Get(context.Background(), "k"); err == nil {
		t.Fatal("want a certificate error")
	}
}

func TestRedisPlainClientCannotTalkToTLSServer(t *testing.T) {
	serverTLS, _ := selfSignedTLS(t)
	f := startFakeRedisWith(t, "", serverTLS)
	c := newRedisCache(f.ln.Addr().String()) // REDIS_TLS unset
	if _, _, err := c.Get(context.Background(), "k"); err == nil {
		t.Fatal("a plain connection to a TLS-only Redis should fail")
	}
}
