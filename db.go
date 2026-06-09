package main

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"sync"

	_ "modernc.org/sqlite"
)

var (
	dbMap   = map[string]*sql.DB{}
	dbMutex sync.Mutex
)

// maxDBMapSize 限制 dbMap 最大条目数，防止恶意/异常客户端用海量 db 名耗尽
// 文件描述符与内存。超过此上限时新 db 名请求直接拒绝。
const maxDBMapSize = 1000

// ErrTooManyDBs 是 getDB 在达到 dbMap 上限时返回的哨兵错误，
// handler 据此返回 400 Bad Request（视为客户端责任）。
var ErrTooManyDBs = errors.New("too many databases: limit is 1000")

// validateName 校验数据库名和键的通用规则：长度1-10，仅小写字母和数字
func validateName(name string) error {
	if len(name) == 0 || len(name) > 10 {
		return errors.New("invalid name: length must be 1-10")
	}
	for _, ch := range name {
		if (ch < 'a' || ch > 'z') && (ch < '0' || ch > '9') {
			return errors.New("invalid name: only lowercase letters and digits allowed")
		}
	}
	return nil
}

func getDataDir() string {
	dir := os.Getenv("KV_DATA_DIR")
	if dir == "" {
		dir = "./data"
	}
	return dir
}

// getDB 返回指定名称的数据库连接，若不存在则自动创建并开启 WAL
func getDB(name string) (*sql.DB, error) {
	if err := validateName(name); err != nil {
		return nil, err
	}

	dbMutex.Lock()
	defer dbMutex.Unlock()

	if db, ok := dbMap[name]; ok {
		return db, nil
	}

	// 容量上限：避免恶意/异常 db 名耗尽 fd 与内存
	if len(dbMap) >= maxDBMapSize {
		return nil, ErrTooManyDBs
	}

	dataDir := getDataDir()
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		return nil, err
	}

	dbPath := filepath.Join(dataDir, name+".db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, err
	}

	// 单连接串行化写操作，避免 SQLITE_BUSY
	db.SetMaxOpenConns(1)

	// 开启 WAL 模式
	if _, err := db.Exec(`PRAGMA journal_mode=WAL`); err != nil {
		db.Close()
		return nil, err
	}

	// 创建 KV 表
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS kv (
		key TEXT PRIMARY KEY,
		value TEXT,
		timeout_after INTEGER NOT NULL DEFAULT 0,
		create_at INTEGER NOT NULL DEFAULT 0
	)`); err != nil {
		db.Close()
		return nil, err
	}

	// 部分索引：仅覆盖有过期配置的记录，加速清理查询
	if _, err := db.Exec(`CREATE INDEX IF NOT EXISTS idx_kv_timeout
		ON kv (timeout_after, create_at)
		WHERE timeout_after > 0`); err != nil {
		db.Close()
		return nil, err
	}

	dbMap[name] = db
	return db, nil
}
