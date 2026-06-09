package main

import (
	"database/sql"
	"io"
	"log"
	"net/http"
	"strconv"
	"time"
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
	var timeoutAfter, createAt int64
	err = db.QueryRow(`SELECT value, timeout_after, create_at FROM kv WHERE key = ?`, key).Scan(&value, &timeoutAfter, &createAt)
	if err == sql.ErrNoRows {
		http.Error(w, "key not found", http.StatusNotFound)
		return
	} else if err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}

	// 命中已过期记录：删除并返回 404
	now := time.Now().Unix()
	if timeoutAfter > 0 && now-createAt > timeoutAfter {
		if _, delErr := db.Exec(`DELETE FROM kv WHERE key = ?`, key); delErr != nil {
			log.Printf("cleanup on get failed: db=%s key=%s: %v", dbName, key, delErr)
		}
		http.Error(w, "key not found", http.StatusNotFound)
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

	// 解析 X-KV-Timeout 头：缺省/空 → 0（永不过期）
	var timeoutAfter int64
	if raw := r.Header.Get("X-KV-Timeout"); raw != "" {
		v, parseErr := strconv.ParseInt(raw, 10, 64)
		if parseErr != nil || v < 0 {
			http.Error(w, "invalid X-KV-Timeout header", http.StatusBadRequest)
			return
		}
		timeoutAfter = v
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

	_, err = db.Exec(
		`INSERT OR REPLACE INTO kv (key, value, timeout_after, create_at) VALUES (?, ?, ?, ?)`,
		key, string(body), timeoutAfter, time.Now().Unix(),
	)
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
