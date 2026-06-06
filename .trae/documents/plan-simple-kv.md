# 实施计划：simple-kv

## 概要

根据 `design.md` 实现一个基于 SQLite（WAL 模式）的 Go HTTP KV API，并准备项目以开源到 GitHub：包含 README / LICENSE / .gitignore，以及在打 `v*` tag 时自动构建并发布 Linux amd64 静态二进制（同一份二进制可同时运行在 glibc 与 musl/Alpine 系统上）的 GitHub Actions。

**用户决策（已确认）**
- License：MIT
- 架构：仅 `linux/amd64`（一个 CGO 关闭的静态二进制，glibc 与 Alpine 通吃）
- Go module 路径：`simple-kv`

**不包含范围（除非用户后续要求）**
- 不包含 Docker / docker-compose
- 不包含 systemd unit
- 不包含其他平台（darwin / windows）和非 amd64 架构
- 不会实际推送到 GitHub（无凭据），但会完成本地 `git init` 与首次提交，使用者只需 `git remote add` + `git push` 即可

---

## 当前状态

- 工作目录 `c:\Users\Administrator\Documents\codes\kv.imhcg.cn\` 仅有 `design.md`
- 无 git 仓库、无 `go.mod`、无源码
- 工具链：Go 1.26.2（设计文档要求 Go 1.22+）

---

## 实施步骤

### 步骤 1：项目骨架

**新建文件（全部在工作目录根）**

| 文件 | 用途 |
|---|---|
| `main.go` | 入口：注册路由、读取 `PORT`、挂鉴权中间件、启动服务（与 design 一致） |
| `db.go` | SQLite 连接管理、`validateName`、WAL 开启、建表（与 design 一致） |
| `handlers.go` | `handleGet` / `handlePut` / `handleDelete`（与 design 一致） |
| `middleware.go` | `authMiddleware`（与 design 一致） |
| `go.mod` | `module simple-kv`，`go 1.22`，`require modernc.org/sqlite v1.29.5` |
| `go.sum` | 由 `go mod tidy` 生成 |
| `.gitignore` | 忽略 `data/`、二进制 `simple-kv`、`.db` / `.db-wal` / `.db-shm`、`*.local`、`.idea/`、`.vscode/` |
| `LICENSE` | MIT 版权声明（年份 2026，版权所有者占位 `imhcg`，用户可自行修改） |
| `README.md` | 项目说明、安装、运行、API 用法、tag 发布流程 |
| `.github/workflows/release.yml` | tag 触发 → 构建 → 打包 → 创建/上传 GitHub Release |

**关于 module 名差异**：design.md 示例里是 `kv-api`，按用户决策改为 `simple-kv`；代码中无 import 该 module 自身的语句，因此仅影响 `go.mod`。

### 步骤 2：代码内容

直接照搬 `design.md` 中的 4 个 Go 文件，**不需要新增逻辑**。需注意：

1. `db.go` 顶部 import `_ "modernc.org/sqlite"`
2. `main.go` 使用 Go 1.22+ 的增强路由（`mux.HandleFunc("GET /{db}/{key}", ...)` + `r.PathValue(...)`）
3. `db.go` 中 `db.SetMaxOpenConns(1)` 用以串行化写、避免 `SQLITE_BUSY`
4. `handlers.go` 中 `PUT` 路径用 `io.LimitReader(r.Body, 50*1024)` 限制 50 KiB

### 步骤 3：依赖管理

执行：
```bash
go mod tidy
```
在 Go 1.26 工具链下会用 `go 1.22` 指令完成解析，生成 `go.sum`。

> 注：design.md 写 `go 1.22`，系统是 1.26.2。Go 的 toolchain 机制会保证兼容性。若 `go mod tidy` 因 1.22 toolchain 未安装而失败，可临时把 `go.mod` 第一行改为 `go 1.22.0` 并在 `go.mod` 末尾添加 `toolchain go1.26.2`（不推荐改 design）。本计划按默认 1.22 处理。

### 步骤 4：本地构建与冒烟测试

执行：
```bash
go build -o simple-kv.exe .
# 或在 Linux runner： go build -o simple-kv .
```

冒烟测试（无 AUTH_TOKEN 模式）：
```bash
./simple-kv.exe &
# 写
curl -sS -X PUT -d "hello" http://localhost:8080/mydb/k1
# 读
curl -sS http://localhost:8080/mydb/k1         # 期望：hello
# 删除
curl -sS -X DELETE -o /dev/null -w "%{http_code}\n" http://localhost:8080/mydb/k1   # 期望：204
# 不存在
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/mydb/k1             # 期望：404
# 非法 key
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8080/mydb/BAD            # 期望：400
```
带 `AUTH_TOKEN=my-secret` 重启后再跑一次 PUT，验证无 token 返回 401。

### 步骤 5：GitHub Actions 发布工作流

**文件**：`.github/workflows/release.yml`

要点：
- 触发条件：`on: push: tags: ['v*']`
- 权限：`permissions: contents: write`（创建 release 需要）
- 作业运行器：`ubuntu-latest`
- Go 版本：`go-version: '1.22'`（与 go.mod 对齐）
- 构建命令：
  ```bash
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
      -ldflags="-s -w -X main.version=${GITHUB_REF_NAME}" \
      -o simple-kv_${GITHUB_REF_NAME}_linux_amd64 .
  ```
  - `CGO_ENABLED=0` + `modernc.org/sqlite`（纯 Go）→ 静态二进制
  - 同一份产物在 glibc 与 musl 系统上均可运行
- 打包：`tar -czf simple-kv_${GITHUB_REF_NAME}_linux_amd64.tar.gz simple-kv`
- 校验和：`sha256sum` 输出到 `checksums.txt`
- 发布：使用 `softprops/action-gh-release@v2`，上传 tar.gz 与 checksums.txt
- Release 标题使用 tag 名；body 自动从 commits 生成（`generate_release_notes: true`）

> 因为是 CGO=0 的单一静态产物，**不再额外构建 musl 变体**——同一二进制即可。README 中会明确说明。

### 步骤 6：README.md 结构

按以下顺序：
1. 项目简介（一段话）
2. 特性（SQLite WAL、纯文本、静态二进制、Bearer 鉴权、数据库/键强校验）
3. 快速开始（curl 三连示例）
4. 安装
   - 下载预编译 release：`simple-kv_vX.Y.Z_linux_amd64.tar.gz`
   - 或 `go install github.com/<owner>/simple-kv@latest`（占位）
5. 配置：环境变量表（PORT / DATA_DIR / AUTH_TOKEN）
6. API：GET / PUT / DELETE 三段
7. 约束：db/key 命名、value 大小上限
8. 发布：如何打 tag 触发 CI
9. License：MIT

### 步骤 7：LICENSE（MIT）

标准 MIT 文本，Copyright 行：
```
Copyright (c) 2026 imhcg
```
（`imhcg` 来自目录名 `kv.imhcg.cn` 的猜测占位，用户可自行替换。）

### 步骤 8：.gitignore

```
# 构建产物
/simple-kv
/simple-kv.exe
/dist/

# 运行时数据
/data/
*.db
*.db-wal
*.db-shm

# IDE
.idea/
.vscode/
*.iml

# 本地配置
.env
*.local
```

### 步骤 9：本地 git 初始化与首次提交

按以下顺序（每条可独立执行）：
```bash
git init
git add .
git commit -m "feat: initial simple-kv implementation

- SQLite (WAL) based KV store via HTTP
- GET / PUT / DELETE /{db}/{key}
- Bearer token auth via AUTH_TOKEN
- GitHub Actions: tag v* builds linux/amd64 static binary"
git tag v0.1.0
```

**不会** 执行 `git push`（没有凭据）。在最终消息中告知用户：
```bash
git remote add origin https://github.com/<owner>/simple-kv.git
git push -u origin main
git push origin v0.1.0   # 触发 Release 工作流
```

---

## 假设与决策记录

| # | 决策 | 理由 |
|---|---|---|
| 1 | 不为 Alpine 单独构建 musl 产物 | `CGO_ENABLED=0` + 纯 Go SQLite 驱动 = 静态二进制，glibc/Alpine 通吃；多产物会让用户困惑。README 会注明 |
| 2 | go.mod 中 `go 1.22`，CI 用 `actions/setup-go@v5` + `go-version: 1.22` | 严格遵循 design.md；Go 1.26 工具链会自动处理 |
| 3 | 不写单元测试 | design.md 未要求；冒烟测试已覆盖关键路径。如后续需要可加 `handlers_test.go` |
| 4 | 不引入 `godotenv` 等依赖 | 仅三个环境变量，直接 `os.Getenv` |
| 5 | 不创建 Docker | 用户未要求；静态二进制 + systemd / Docker 都能直接用 |
| 6 | `version` 不通过 `-ldflags` 注入包内变量 | design.md 中无 `main.version` 引用；为保持最小变更，**省去 ldflags 中的 `-X main.version`**。如用户需要打印版本号再加一行。 |
| 7 | 不用 `goreleaser` | 单架构单 OS，shell 步骤更直观、零额外依赖 |
| 8 | License 中 Copyright 占位 `imhcg` | 由目录名 `kv.imhcg.cn` 推测 |

---

## 验证清单

实施完成后必须全部通过：

- [ ] `go mod tidy` 成功，`go.sum` 生成
- [ ] `go vet ./...` 无告警
- [ ] `go build` 生成本地二进制
- [ ] 冒烟测试（步骤 4）所有 curl 期望值匹配
- [ ] `AUTH_TOKEN` 模式下无 token 请求返回 401
- [ ] `git log` 存在初始 commit
- [ ] `git tag v0.1.0` 成功（不推送）
- [ ] `.github/workflows/release.yml` YAML 可被 `actionlint` 或 GitHub 解析（人工 review）
- [ ] 文件清单：main.go / db.go / handlers.go / middleware.go / go.mod / go.sum / README.md / LICENSE / .gitignore / .github/workflows/release.yml

---

## 风险与回退

- **Go 1.22 toolchain 未安装**：`go mod tidy` 会自动下载；若环境无外网会失败。回退：把 `go.mod` 改为 `go 1.22.0` 并加 `toolchain go1.26.2`，让本机 1.26.2 直接编译。
- **modernc.org/sqlite 版本变更**：CI 不锁次版本；若担心可加 `// indirect` 校验。本次按 `v1.29.5` 锁定（design 写的就是这个）。
- **GitHub Action 第一次跑失败**：常见原因是权限未开（需 repo Settings → Actions → Workflow permissions 选 Read and write）。在 README 注明即可。

---

## 附：交付物清单

| 路径 | 类型 | 来源 |
|---|---|---|
| `main.go` | 源码 | design.md |
| `db.go` | 源码 | design.md |
| `handlers.go` | 源码 | design.md |
| `middleware.go` | 源码 | design.md |
| `go.mod` | 依赖 | design.md（module 改 `simple-kv`） |
| `go.sum` | 依赖 | `go mod tidy` 生成 |
| `.gitignore` | 配置 | 本计划 |
| `README.md` | 文档 | 本计划 |
| `LICENSE` | 法律 | MIT，本计划生成 |
| `.github/workflows/release.yml` | CI | 本计划 |
