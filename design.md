

# 最小可用 KV API 设计文档

## 概述
使用 Go 语言实现基于 SQLite 的 Key-Value 存储 API，通过 HTTP 提供增删查改操作。采用 WAL 模式提升并发性能，仅暴露 HTTP 端口（供 CDN 回源），通过环境变量进行简单鉴权。

### 约束规则
- **数据库名**：仅允许小写字母和数字 `[a-z0-9]+`，长度 ≤ 10
- **键（Key）**：仅允许小写字母和数字 `[a-z0-9]+`，长度 ≤ 10
- **值（Value）**：纯文本，最大请求体限制 50 KiB
- **鉴权**：若设置环境变量 `AUTH_TOKEN`，则要求请求头 `Authorization: Bearer <token>`
- **数据隔离**：每个数据库名对应 `data/` 目录下的独立 `.db` 文件，首次访问自动创建

---

## 项目结构

```
kv-api/
├── main.go          # 入口，注册路由，启动服务
├── db.go            # 数据库连接管理（SQLite 初始化、WAL 开启）
├── handlers.go      # HTTP 请求处理（GET、PUT、DELETE）
├── middleware.go    # 鉴权中间件
├── go.mod
└── go.sum
```

**依赖**：
- `modernc.org/sqlite` (纯 Go 实现的 SQLite 驱动，无需 CGO)
- Go 1.22+ (利用标准库增强路由功能)

---

## 环境变量

| 变量名      | 默认值     | 说明                                |
|-------------|------------|-------------------------------------|
| `KV_PORT`      | `8080`     | HTTP 监听端口                       |
| `KV_DATA_DIR`  | `./data`   | 数据库文件存储目录                  |
| `KV_AUTH_TOKEN`| 空（可选） | 若设置则启用 Bearer Token 鉴权      |

---

## API 接口

所有接口均返回纯文本（Content-Type: text/plain; charset=utf-8）。

### 1. 获取键值
- **方法**：`GET /{db}/{key}`
- **成功响应**：`200 OK`，响应体为键对应的值
- **键不存在**：`404 Not Found`
- **示例**：
  ```bash
  curl http://localhost:8080/mydb/mykey
  ```

### 2. 设置/更新键值
- **方法**：`PUT /{db}/{key}`
- **请求体**：纯文本值（≤ 50 KiB）
- **成功响应**：`200 OK`
- **示例**：
  ```bash
  curl -X PUT -d "hello world" http://localhost:8080/mydb/mykey
  ```

### 3. 删除键
- **方法**：`DELETE /{db}/{key}`
- **成功响应**：`204 No Content`
- **键不存在**：`404 Not Found`
- **示例**：
  ```bash
  curl -X DELETE http://localhost:8080/mydb/mykey
  ```

---

## 完整代码

### go.mod

```go
module kv-api

go 1.22

require modernc.org/sqlite v1.29.5
```

### main.go

```go
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

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	handler := authMiddleware(mux)

	log.Printf("KV API listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, handler))
}
```

### db.go

```go
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
	dir := os.Getenv("DATA_DIR")
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
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)`); err != nil {
		db.Close()
		return nil, err
	}

	dbMap[name] = db
	return db, nil
}
```

### handlers.go

```go
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
```

### middleware.go

```go
package main

import (
	"net/http"
	"os"
	"strings"
)

func authMiddleware(next http.Handler) http.Handler {
	token := os.Getenv("AUTH_TOKEN")
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
```

---

## 构建与运行

```bash
# 初始化模块（若未创建）
go mod init kv-api
go get modernc.org/sqlite@latest

# 可选：设置鉴权 Token
export AUTH_TOKEN=my-secret

# 启动服务
go run .

# 或编译后运行
go build -o kv-api .
./kv-api
```

服务默认监听 `http://localhost:8080`。

---

## 测试示例

```bash
# 数据库名：mydb（允许数字），键：k1（允许数字）
curl -X PUT -d "hello" \
  -H "Authorization: Bearer my-secret" \
  http://localhost:8080/mydb/k1

# 读取
curl http://localhost:8080/mydb/k1

# 删除
curl -X DELETE http://localhost:8080/mydb/k1
```

---
