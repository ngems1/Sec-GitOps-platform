// Week 3: catalog data from RDS MySQL with a Redis cache in front (cache-aside).
//
//	request -> Redis GET  -- hit  --> answer from the cache
//	                      -- miss --> MySQL SELECT -> Redis SET (TTL) -> answer
//
// The shop never breaks because of the data layer:
//   - Redis down         -> read MySQL directly
//   - MySQL down         -> last catalog read successfully, else products.json
//   - both down          -> products.json (the image's built-in catalog)
//
// Hits and misses are counted and summarised in the log once a minute
// ("catalog cache stats"), and every MySQL load is logged.
package main

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	pb "github.com/GoogleCloudPlatform/microservices-demo/src/productcatalogservice/genproto"
)

const catalogCacheKey = "productcatalog:products:v1"

// productSource is where products really live (MySQL, or a fake in tests).
type productSource interface {
	LoadProducts(ctx context.Context) ([]*pb.Product, error)
}

type catalogStats struct {
	hits, misses, dbLoads, dbErrors, cacheErrors, stale, fallbacks atomic.Int64
}

type catalogLoader struct {
	source   productSource
	cache    cacheStore // nil = no cache, MySQL on every request
	ttl      time.Duration
	fallback func() []*pb.Product // products.json
	encode   func([]*pb.Product) ([]byte, error)
	decode   func([]byte) ([]*pb.Product, error)

	loadMu   sync.Mutex // one MySQL load at a time
	lastMu   sync.RWMutex
	lastGood []*pb.Product

	stats catalogStats
}

// products returns the catalog, from the cache if possible.
func (l *catalogLoader) products(ctx context.Context) []*pb.Product {
	if ps, ok := l.fromCache(ctx); ok {
		l.stats.hits.Add(1)
		return ps
	}
	l.stats.misses.Add(1)

	// Miss: load from MySQL. Concurrent misses wait for one load instead of all
	// hitting the database at once, then re-check the cache.
	l.loadMu.Lock()
	defer l.loadMu.Unlock()
	if ps, ok := l.fromCache(ctx); ok {
		return ps
	}

	loadCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	start := time.Now()
	ps, err := l.source.LoadProducts(loadCtx)
	if err != nil || len(ps) == 0 {
		l.stats.dbErrors.Add(1)
		if err == nil {
			log.WithContext(ctx).Warn("catalog: MySQL returned no products")
		} else {
			log.WithContext(ctx).WithError(err).Warn("catalog: MySQL load failed")
		}
		if last := l.last(); len(last) > 0 {
			l.stats.stale.Add(1)
			log.WithContext(ctx).Warnf("catalog: serving the last catalog read from MySQL (%d products)", len(last))
			return last
		}
		l.stats.fallbacks.Add(1)
		log.WithContext(ctx).Warn("catalog: serving the built-in products.json")
		return l.fallback()
	}

	l.stats.dbLoads.Add(1)
	l.setLast(ps)
	cached := "no cache configured"
	if l.cache != nil {
		cached = "cache write failed"
		if data, err := l.encode(ps); err == nil {
			if err := l.cache.Set(ctx, catalogCacheKey, data, l.ttl); err == nil {
				cached = "cached for " + l.ttl.String()
			} else {
				l.stats.cacheErrors.Add(1)
				log.WithContext(ctx).WithError(err).Warn("catalog: Redis SET failed")
			}
		}
	}
	log.WithContext(ctx).WithField("products", len(ps)).WithField("ms", time.Since(start).Milliseconds()).
		Infof("catalog cache miss: loaded %d products from MySQL, %s", len(ps), cached)
	return ps
}

func (l *catalogLoader) fromCache(ctx context.Context) ([]*pb.Product, bool) {
	if l.cache == nil {
		return nil, false
	}
	data, found, err := l.cache.Get(ctx, catalogCacheKey)
	if err != nil {
		l.stats.cacheErrors.Add(1)
		log.WithContext(ctx).WithError(err).Warn("catalog: Redis GET failed, reading MySQL")
		return nil, false
	}
	if !found {
		return nil, false
	}
	ps, err := l.decode(data)
	if err != nil || len(ps) == 0 {
		l.stats.cacheErrors.Add(1)
		log.WithContext(ctx).WithError(err).Warn("catalog: unreadable cache entry, reading MySQL")
		return nil, false
	}
	return ps, true
}

func (l *catalogLoader) last() []*pb.Product {
	l.lastMu.RLock()
	defer l.lastMu.RUnlock()
	return l.lastGood
}

func (l *catalogLoader) setLast(ps []*pb.Product) {
	l.lastMu.Lock()
	defer l.lastMu.Unlock()
	l.lastGood = ps
}

// logStats writes one summary line per interval when there was traffic.
func (l *catalogLoader) logStats(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	var prevHits, prevMisses int64
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			hits, misses := l.stats.hits.Load(), l.stats.misses.Load()
			dh, dm := hits-prevHits, misses-prevMisses
			prevHits, prevMisses = hits, misses
			if dh+dm == 0 {
				continue
			}
			log.WithField("hits", dh).WithField("misses", dm).
				WithField("hitRatePct", 100*dh/(dh+dm)).
				WithField("totalHits", hits).WithField("totalMisses", misses).
				WithField("mysqlLoads", l.stats.dbLoads.Load()).
				WithField("mysqlErrors", l.stats.dbErrors.Load()).
				WithField("redisErrors", l.stats.cacheErrors.Load()).
				WithField("fallbacks", l.stats.fallbacks.Load()).
				Infof("catalog cache stats (last %s): %d hits, %d misses", every, dh, dm)
		}
	}
}
