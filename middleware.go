package main

import (
	"net/http"
	"os"
	"strings"
)

func authMiddleware(next http.Handler) http.Handler {
	token := os.Getenv("KV_AUTH_TOKEN")
	if token == "" {
		return next
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") || auth[7:] != token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
