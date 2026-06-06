package main

import (
	"database/sql"
	"io"
	"net/http"
)

func handleGet(w http.ResponseWriter, r *http.Request) {
	dbName := r.PathValue("db")
	key := r.PathValue("key")
	if err := validateName(key); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	db, err := getDB(dbName)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	var value string
	err = db.QueryRow(`SELECT value FROM kv WHERE key = ?`, key).Scan(&value)
	if err == sql.ErrNoRows {
		http.Error(w, "key not found", http.StatusNotFound)
		return
	} else if err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte(value))
}

func handlePut(w http.ResponseWriter, r *http.Request) {
	dbName := r.PathValue("db")
	key := r.PathValue("key")
	if err := validateName(key); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// 限制请求体大小为 50 KiB
	body, err := io.ReadAll(io.LimitReader(r.Body, 50*1024))
	if err != nil {
		http.Error(w, "failed to read request body", http.StatusBadRequest)
		return
	}

	db, err := getDB(dbName)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	_, err = db.Exec(`INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)`, key, string(body))
	if err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
}

func handleDelete(w http.ResponseWriter, r *http.Request) {
	dbName := r.PathValue("db")
	key := r.PathValue("key")
	if err := validateName(key); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	db, err := getDB(dbName)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	res, err := db.Exec(`DELETE FROM kv WHERE key = ?`, key)
	if err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}

	rows, _ := res.RowsAffected()
	if rows == 0 {
		http.Error(w, "key not found", http.StatusNotFound)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
