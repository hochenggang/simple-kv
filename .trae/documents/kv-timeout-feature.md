# KV 过期功能改造计划

## 1. Summary（概述）

为 simple-kv 引入记录级 TTL 能力：
- `kv` 表新增 `timeout_after`（过期秒数，0 = 永不过期）和 `create_at`（秒级 UTC 时间戳）两列
- 客户端通过 `X-KV-Timeout` 请求头在 PUT 时设置 `timeout_after`；缺省/0 即永不过期
- 后台 goroutine 每分钟清理一次已过期记录，单次最多 1000 条
- GET 命中已过期记录时直接删除并返回 404

---

## 2. Current State Analysis（现状分析）

阅读并理解了项目 4 个核心文件：

- [main.go](file:///c:/Users/Administrator/Documents/codes/kv.imhcg.cn/main.go#L1-L33)
  - 启动 HTTP server，注册 3 条路由（GET/PUT/DELETE），使用 `KV_HOST` / `KV_PORT` / `KV_AUTH_TOKEN` 环境变量
  - 中间件链 `corsMiddleware(authMiddleware(mux))`

- [db.go](file:///c:/Users/Administrator/Documents/codes/kv.imhcg.cn/db.go#L40-L80)
  - `getDB(name)` 懒加载 SQLite 连接，WAL 模式，`SetMaxOpenConns(1)` 串行化写
  - `CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)` 现有 schema
  - 全局 `dbMap map[string]*sql.DB` + `dbMutex` 保护
  - `validateName`：长度 1-10、仅 `[a-z0-9]`

- [handlers.go](file:///c:/Users/Administrator/Documents/codes/kv.imhcg.cn/handlers.go#L9-L94)
  - `handleGet`：`SELECT value FROM kv WHERE key = ?`
  - `handlePut`：`INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)`，body 上限 50 KiB
  - `handleDelete`：`DELETE FROM kv WHERE key = ?`，无匹配返回 404

- [middleware.go](file:///c:/Users/Administrator/Documents/codes/kv.imhcg.cn/middleware.go#L1-L42)
  - CORS 全放行 + Bearer token 鉴权

- [go.mod](file:///c:/Users/Administrator/Documents/codes/kv.imhcg.cn/go.mod)：模块名 `simple-kv`，Go 1.22，依赖 `modernc.org/sqlite v1.29.5`

**关键约束**：
- 每库 `SetMaxOpenConns(1)`，所有 SQL 串行执行——后台清理会与 HTTP 请求复用同一连接，简单可靠
- 用户已确认：不考虑向后兼容（不需要 ALTER TABLE 兼容老库），create_at 在 PUT 时重置，timeout_after 通过 HTTP 头设置

---

## 3. Proposed Changes（具体改动）

### 3.1 新增文件 `cleanup.go`

**目的**：后台过期清理 goroutine，单职责。

**关键设计**：
- 函数 `startCleanup(ctx context.Context)` 启动 goroutine，使用 `time.NewTicker(1 * time.Minute)`
- 每 tick 遍历 `dbMap` 中所有活跃 DB，执行：
  ```sql
  DELETE FROM kv
  WHERE timeout_after > 0
    AND (strftime('%s','now') - create_at) > timeout_after
  LIMIT 1000
  ```
  （SQLite 自 3.7 起支持 `DELETE ... LIMIT`）
- 用 `res.RowsAffected()` 统计本轮删除数，记日志
- 每 tick 结束 sleep 短暂随机抖动（避免多副本同时清理），但用户没要求，先不做
- ctx 取消时退出 goroutine
- 错误不中断循环：单 DB 出错 log 后继续下一个 DB

### 3.2 修改 `db.go`

**改动点**：
1. `getDB` 内 `CREATE TABLE` 语句扩展为：
   ```sql
   CREATE TABLE IF NOT EXISTS kv (
     key TEXT PRIMARY KEY,
     value TEXT,
     timeout_after INTEGER NOT NULL DEFAULT 0,
     create_at INTEGER NOT NULL DEFAULT 0
   )
   ```
2. 紧接其后创建索引，加速清理查询（即使无索引也走全表，但有索引更省 CPU）：
   ```sql
   CREATE INDEX IF NOT EXISTS idx_kv_timeout
     ON kv (timeout_after, create_at)
     WHERE timeout_after > 0
   ```
   （partial index 只覆盖有过期配置的记录，体量小）
3. 不加 `ALTER TABLE`——用户明确不考虑兼容

### 3.3 修改 `handlers.go`

**`handlePut`**：
- 读取请求头 `X-KV-Timeout`，`strconv.ParseInt(s, 10, 64)` 解析为秒数
- 解析失败或负数 → `400 Bad Request`，body 提示 `invalid X-KV-Timeout header`
- 缺省或空字符串 → 0（永不过期）
- `now := time.Now().Unix()`
- `INSERT OR REPLACE` 改为：
  ```sql
  INSERT OR REPLACE INTO kv (key, value, timeout_after, create_at)
  VALUES (?, ?, ?, ?)
  ```
  参数：key, body, timeoutAfter, now

**`handleGet`**：
- SELECT 改为读取三列：
  ```sql
  SELECT value, timeout_after, create_at FROM kv WHERE key = ?
  ```
- 拿到 `value`, `timeoutAfter`, `createAt`（int64）
- 过期判断：
  ```go
  now := time.Now().Unix()
  if timeoutAfter > 0 && now-createAt > timeoutAfter {
      // 异步删除避免阻塞当前连接太久？同步即可，单 DELETE < 1ms
      db.Exec(`DELETE FROM kv WHERE key = ?`, key)
      http.Error(w, "key not found", http.StatusNotFound)
      return
  }
  ```
  - 删除失败不报错（最坏情况是清理周期兜底），log warn 即可
  - 不做事务包裹：SELECT 与 DELETE 间理论上另一 goroutine 可能再写这个 key，但因单连接串行 + 写时也会重置 create_at，最多导致一个被并发 PUT 重置的 key 被当前 handler 删除一次，仍满足"已过期才删"的语义

**`handleDelete`**：保持不变。已过期 key 仍可被显式 DELETE（返回 204 即可，不必判 404）。

### 3.4 修改 `main.go`

- 引入 `context` 包
- 在 `http.ListenAndServe` 之前启动 cleanup：
  ```go
  ctx, cancel := context.WithCancel(context.Background())
  defer cancel()
  go startCleanup(ctx)
  ```
- 其余代码不动
- 注：服务当前无 graceful shutdown；cleanup goroutine 会在 main 返回时随进程一起退出，可接受

### 3.5 （可选）`README.md` / `design.md` 更新

用户没要求，但作为"优化"的一部分建议同步：
- README 新增 `X-KV-Timeout` 头说明
- 补充"过期与清理"小节

**本计划默认不更新文档**，保持范围最小；如需可单独追加。

---

## 4. Assumptions & Decisions（假设与决策）

| # | 决策 | 理由 |
|---|---|---|
| 1 | `X-KV-Timeout` 头缺省/空 → 0 | 用户要求"设为 0 时为不过期记录"，缺省即不过期最符合直觉 |
| 2 | 清理 SQL 用 SQLite 原生 `strftime('%s','now')` | 自包含、不依赖 Go 端传参；UTC 语义清晰 |
| 3 | 清理与 HTTP 共用同一 DB 连接 | 单连接设计本就为简化；清理每秒最多 1 次、限 1000 行，延迟影响极小 |
| 4 | GET 过期删除不做事务包裹 | 单连接串行+删除幂等，不会出现数据不一致；不增加复杂度 |
| 5 | cleanup 出错不退出 goroutine | 单库异常不应让其他库停止清理 |
| 6 | 不写文档/不发版 | 用户没要求；按"做且仅做被要求的事"原则 |
| 7 | `timeout_after` / `create_at` 列类型 `INTEGER` | SQLite 弱类型；`int64` 秒级时间戳到 2038+ 仍远在范围内 |
| 8 | 不在 PUT 路径里做"保留首次 create_at" | 用户明确选"重置为当前时间"，简单 `INSERT OR REPLACE` 即可 |

---

## 5. Verification（验证步骤）

1. **编译**：`go build ./...` 应无错误
2. **启动**：`go run .` 监听 `:8080`，日志含 `KV API listening on`
3. **基础读写**：
   ```bash
   curl -X PUT -d "hello" http://localhost:8080/mydb/k1        # 永不过期
   curl http://localhost:8080/mydb/k1                          # → hello
   curl -X PUT -H "X-KV-Timeout: 2" -d "tmp" http://localhost:8080/mydb/k2
   curl http://localhost:8080/mydb/k2                          # → tmp
   sleep 65
   curl http://localhost:8080/mydb/k2                          # → 404（清理触发或 GET 触发）
   curl http://localhost:8080/mydb/k1                          # → hello（未过期）
   ```
4. **GET 触发懒删除**：写入 `timeout=1`，sleep 2s 后 GET 一次返回 404，再 GET 一次仍 404（验证已被删除）
5. **后台清理**：往库里写 10 条 `timeout=1`，等 65s 观察日志 `cleaned N records`
6. **非法头**：
   ```bash
   curl -X PUT -H "X-KV-Timeout: abc" -d "x" ...   # 400
   curl -X PUT -H "X-KV-Timeout: -1" -d "x" ...    # 400
   ```
7. **并发**：起 2 个 goroutine 同时 GET 同一过期 key，验证 2 个都拿到 404，且库里记录只被删一次（DELETE 幂等）
8. **多 DB**：在 `db1`、`db2` 各写过期 key，确认清理都能覆盖

---

## 6. Files to Touch（最终改动清单）

- [db.go](file:///c:/Users/Administrator/Documents/codes/kv.imhcg.cn/db.go) — 修改 schema + 加索引
- [handlers.go](file:///c:/Users/Administrator/Documents/codes/kv.imhcg.cn/handlers.go) — PUT 解析新头、GET 加过期检查
- [main.go](file:///c:/Users/Administrator/Documents/codes/kv.imhcg.cn/main.go) — 启动 cleanup goroutine
- `cleanup.go` — **新增**，~40 行后台清理逻辑
