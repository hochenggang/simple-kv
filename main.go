package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"golang.org/x/time/rate"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{db}/{key}", handleGet)
	mux.HandleFunc("PUT /{db}/{key}", handlePut)
	mux.HandleFunc("DELETE /{db}/{key}", handleDelete)

	// 启动后台过期清理（每分钟一次，单库单次最多 1000 条）
	cleanupCtx, cancelCleanup := context.WithCancel(context.Background())
	defer cancelCleanup()
	go startCleanup(cleanupCtx)

	host := os.Getenv("KV_HOST")
	if host == "" {
		host = "0.0.0.0"
	}
	port := os.Getenv("KV_PORT")
	if port == "" {
		port = "8080"
	}

	addr := net.JoinHostPort(host, port)

	// IP 限流池：每 IP 5 req/s，突发 10；池容量 1000，超出 FIFO 淘汰
	rlPool := newIPRateLimiterPool(1000, rate.Limit(5), 10)

	// 中间件链：CORS（最外，预检短路） -> 限流（未鉴权攻击也被限） -> 鉴权 -> mux
	handler := corsMiddleware(rateLimitMiddleware(rlPool, authMiddleware(mux)))

	// 显式超时，防止 Slowloris 与慢客户端占满 fd
	srv := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadTimeout:       10 * time.Second,
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf("KV API listening on %s", addr)
	log.Fatal(srv.ListenAndServe())
}
