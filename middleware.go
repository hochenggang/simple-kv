package main

import (
	"crypto/subtle"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"

	"golang.org/x/time/rate"
)

// corsMiddleware allows any origin to call the API. It is intentionally
// permissive (Access-Control-Allow-Origin: *) because simple-kv is meant to
// be used as a public CDN-origin KV store. Preflight OPTIONS requests are
// short-circuited with a 204.
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-KV-Timeout")
		w.Header().Set("Access-Control-Max-Age", "86400")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// authMiddleware 使用 crypto/subtle 做恒定时间 token 比较，避免计时攻击。
func authMiddleware(next http.Handler) http.Handler {
	token := os.Getenv("KV_AUTH_TOKEN")
	if token == "" {
		return next
	}

	tokenBytes := []byte(token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") ||
			subtle.ConstantTimeCompare([]byte(auth[len("Bearer "):]), tokenBytes) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// clientIP 提取远端 IP（忽略端口）。未配置反向代理时直接用 RemoteAddr。
func clientIP(r *http.Request) string {
	if ip, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return ip
	}
	return r.RemoteAddr
}

// ipRateLimiterPool 按 IP 维护 rate.Limiter 池，容量上限 maxIPs。
// 超出容量时按 FIFO 淘汰最久未更新的条目，防止内存无限增长。
type ipRateLimiterPool struct {
	mu       sync.Mutex
	limiters map[string]*rate.Limiter
	order    []string // FIFO 插入顺序，淘汰时从头取
	maxSize  int
	rate     rate.Limit
	burst    int
}

func newIPRateLimiterPool(maxSize int, r rate.Limit, burst int) *ipRateLimiterPool {
	return &ipRateLimiterPool{
		limiters: make(map[string]*rate.Limiter, maxSize),
		order:    make([]string, 0, maxSize),
		maxSize:  maxSize,
		rate:     r,
		burst:    burst,
	}
}

func (p *ipRateLimiterPool) allow(ip string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()

	if lim, ok := p.limiters[ip]; ok {
		return lim.Allow()
	}

	// 容量满则 FIFO 淘汰最旧条目
	if len(p.limiters) >= p.maxSize {
		oldest := p.order[0]
		p.order = p.order[1:]
		delete(p.limiters, oldest)
	}

	lim := rate.NewLimiter(p.rate, p.burst)
	p.limiters[ip] = lim
	p.order = append(p.order, ip)
	return lim.Allow()
}

// rateLimitMiddleware 按 IP 限流，命中上限返回 429。
// 放在 CORS 之后、auth 之前：OPTIONS 预检不会到这里；未鉴权攻击也被限速。
func rateLimitMiddleware(pool *ipRateLimiterPool, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !pool.allow(clientIP(r)) {
			http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
			return
		}
		next.ServeHTTP(w, r)
	})
}
