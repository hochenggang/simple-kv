package main

import (
	"context"
	"database/sql"
	"log"
	"time"
)

// startCleanup 启动后台清理 goroutine：每分钟清理一次已过期记录，
// 单个数据库单次最多删除 1000 条。ctx 取消时退出。
//
// 与 HTTP 请求复用同一 DB 连接：单连接串行化设计本就为简化资源，
// 清理频率低、命中索引，单次删除延迟可忽略。
func startCleanup(ctx context.Context) {
	ticker := time.NewTicker(1 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			runCleanup()
		}
	}
}

func runCleanup() {
	// 快照当前活跃的 DB，避免与 getDB 的 dbMutex 长期争用
	dbMutex.Lock()
	dbs := make([]*sql.DB, 0, len(dbMap))
	for _, db := range dbMap {
		dbs = append(dbs, db)
	}
	dbMutex.Unlock()

	totalDeleted := 0
	for _, db := range dbs {
		deleted, err := cleanupDB(db)
		if err != nil {
			log.Printf("cleanup error: %v", err)
			continue
		}
		totalDeleted += int(deleted)
	}
	if totalDeleted > 0 {
		log.Printf("cleanup: deleted %d expired records", totalDeleted)
	}
}

func cleanupDB(db *sql.DB) (int64, error) {
	res, err := db.Exec(`DELETE FROM kv
		WHERE timeout_after > 0
		  AND (strftime('%s','now') - create_at) > timeout_after
		LIMIT 1000`)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
