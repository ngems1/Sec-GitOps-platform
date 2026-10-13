// Week 3: a minimal Redis client for the catalog cache (ElastiCache).
//
// Only the two commands the cache needs: GET and SET ... EX. It speaks the Redis
// protocol (RESP) over one TCP connection, reconnecting after any error, so no
// extra library is needed. With useTLS the connection is TLS (ElastiCache encryption
// in transit), and with a password it sends AUTH right after connecting. Every call has a short deadline: a slow or missing
// Redis makes the catalog fall back to MySQL instead of slowing the shop down.
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"time"
)

// cacheStore is what the catalog loader needs from a cache (Redis, or a fake in tests).
type cacheStore interface {
	Get(ctx context.Context, key string) (value []byte, found bool, err error)
	Set(ctx context.Context, key string, value []byte, ttl time.Duration) error
}

type redisCache struct {
	addr    string
	timeout time.Duration

	useTLS    bool        // REDIS_TLS=true: ElastiCache with encryption in transit
	password  string      // REDIS_PASSWORD: ElastiCache auth token, sent with AUTH
	tlsConfig *tls.Config // nil = system CAs, server name from addr (tests set their own CA)

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

func newRedisCache(addr string) *redisCache {
	return &redisCache{addr: addr, timeout: 500 * time.Millisecond}
}

func (r *redisCache) Get(ctx context.Context, key string) ([]byte, bool, error) {
	reply, err := r.do(ctx, "GET", key)
	if err != nil {
		return nil, false, err
	}
	if reply == nil {
		return nil, false, nil // key missing or expired
	}
	return reply, true, nil
}

func (r *redisCache) Set(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	secs := int64(ttl / time.Second)
	if secs < 1 {
		secs = 1
	}
	_, err := r.do(ctx, "SET", key, string(value), "EX", strconv.FormatInt(secs, 10))
	return err
}

// do sends one command and reads its reply. nil reply = Redis "nil" (missing key).
func (r *redisCache) do(ctx context.Context, args ...string) ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	deadline := time.Now().Add(r.timeout)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}

	if r.conn == nil {
		conn, err := r.dial(ctx)
		if err != nil {
			return nil, fmt.Errorf("redis connect %s: %w", r.addr, err)
		}
		r.conn, r.rd = conn, bufio.NewReader(conn)
		if r.password != "" {
			_ = r.conn.SetDeadline(deadline)
			if _, err := r.roundTrip([]string{"AUTH", r.password}); err != nil {
				r.conn.Close()
				r.conn, r.rd = nil, nil
				return nil, fmt.Errorf("redis auth: %w", err) // never includes the token
			}
		}
	}

	_ = r.conn.SetDeadline(deadline)

	reply, err := r.roundTrip(args)
	if err != nil {
		var redisErr redisError
		if !errors.As(err, &redisErr) {
			// network or protocol problem: drop the connection, reconnect next time
			r.conn.Close()
			r.conn, r.rd = nil, nil
		}
		return nil, err
	}
	return reply, nil
}

// dial opens the TCP connection, wrapped in TLS when useTLS is set. The server
// certificate is checked against the system CAs and the endpoint's host name.
func (r *redisCache) dial(ctx context.Context) (net.Conn, error) {
	d := net.Dialer{Timeout: r.timeout}
	if !r.useTLS {
		return d.DialContext(ctx, "tcp", r.addr)
	}
	cfg := r.tlsConfig
	if cfg == nil {
		host, _, err := net.SplitHostPort(r.addr)
		if err != nil {
			host = r.addr
		}
		cfg = &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}
	}
	td := tls.Dialer{NetDialer: &d, Config: cfg}
	return td.DialContext(ctx, "tcp", r.addr)
}

func (r *redisCache) roundTrip(args []string) ([]byte, error) {
	if _, err := r.conn.Write(encodeCommand(args)); err != nil {
		return nil, fmt.Errorf("redis write: %w", err)
	}
	return readReply(r.rd)
}

// redisError is an error reply from Redis itself ("-ERR ..."); the connection is still fine.
type redisError string

func (e redisError) Error() string { return "redis: " + string(e) }

// encodeCommand builds a RESP array of bulk strings: *2\r\n$3\r\nGET\r\n$3\r\nkey\r\n
func encodeCommand(args []string) []byte {
	buf := []byte("*" + strconv.Itoa(len(args)) + "\r\n")
	for _, a := range args {
		buf = append(buf, '$')
		buf = strconv.AppendInt(buf, int64(len(a)), 10)
		buf = append(buf, '\r', '\n')
		buf = append(buf, a...)
		buf = append(buf, '\r', '\n')
	}
	return buf
}

// readReply reads one RESP reply: +simple, -error, :integer, $bulk (or $-1 = nil).
func readReply(rd *bufio.Reader) ([]byte, error) {
	line, err := rd.ReadString('\n')
	if err != nil {
		return nil, fmt.Errorf("redis read: %w", err)
	}
	if len(line) < 3 || line[len(line)-2] != '\r' {
		return nil, fmt.Errorf("redis: malformed reply %q", line)
	}
	kind, body := line[0], line[1:len(line)-2]
	switch kind {
	case '+', ':':
		return []byte(body), nil
	case '-':
		return nil, redisError(body)
	case '$':
		n, err := strconv.Atoi(body)
		if err != nil {
			return nil, fmt.Errorf("redis: bad bulk length %q", body)
		}
		if n < 0 {
			return nil, nil
		}
		data := make([]byte, n+2) // value + \r\n
		if _, err := io.ReadFull(rd, data); err != nil {
			return nil, fmt.Errorf("redis read: %w", err)
		}
		return data[:n], nil
	default:
		return nil, fmt.Errorf("redis: unexpected reply type %q", kind)
	}
}
