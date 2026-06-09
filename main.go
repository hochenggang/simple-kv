package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"
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

	// corsMiddleware is wrapped outermost so OPTIONS preflight is answered
	// without going through auth. The chain is: cors -> auth -> mux.
	handler := corsMiddleware(authMiddleware(mux))

	log.Printf("KV API listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, handler))
}
