package main

import (
	"log"
	"net/http"
	"os"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{db}/{key}", handleGet)
	mux.HandleFunc("PUT /{db}/{key}", handlePut)
	mux.HandleFunc("DELETE /{db}/{key}", handleDelete)

	port := os.Getenv("KV_PORT")
	if port == "" {
		port = "8080"
	}

	handler := authMiddleware(mux)

	log.Printf("KV API listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, handler))
}
