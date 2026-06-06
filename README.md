# simple-kv

一个极简的 HTTP Key-Value 存储服务，基于 Go + SQLite（WAL 模式），适合作为 CDN 回源的轻量后端。

## 特性

- 纯 Go 实现，无 CGO 依赖，**单一静态二进制**即可在 glibc 与 musl（Alpine）系统上运行
- SQLite WAL 模式，单 DB 文件落盘，支持多数据库名隔离
- 仅暴露 HTTP 端口，可直接被 CDN 回源调用
- 可选 Bearer Token 鉴权（`KV_AUTH_TOKEN` 环境变量）
- 严格的输入校验：db / key 仅允许小写字母与数字，长度 1–10
- value 限制为 50 KiB 纯文本

## 快速开始

```bash
# 写
curl -X PUT -d "hello world" http://localhost:8080/mydb/mykey

# 读
curl http://localhost:8080/mydb/mykey
# -> hello world

# 删
curl -X DELETE http://localhost:8080/mydb/mykey
```

## 安装

### 推荐：一键安装（systemd / OpenRC）

项目自带 [`install.sh`](./install.sh)，自动从 GitHub Releases 拉取最新版本、解压、注册为系统服务并拉起守护进程。适用于 Debian / Ubuntu / CentOS / RHEL / Arch（systemd）以及 Alpine（OpenRC）。

```bash
curl -fsSL https://raw.githubusercontent.com/hochenggang/simple-kv/main/install.sh | sudo sh
```

- 首次安装会交互式询问监听端口，回车使用默认 **18100**。
- 服务以 `nobody` 用户运行，从 `/etc/simple-kv/simple-kv.env` 读取 `KV_PORT` / `KV_AUTH_TOKEN`。
- 再次执行即为升级：停止旧服务 → 替换二进制 → 重新拉起，**保留现有配置**。
- 非交互安装（`curl ... | sh`）默认使用端口 18100。
- 指定版本：`curl -fsSL .../install.sh | sudo sh -s -- v0.1.0`

管理命令：

```bash
# Debian/Ubuntu/CentOS/... (systemd)
sudo systemctl status simple-kv
sudo systemctl restart simple-kv
sudo journalctl -u simple-kv -f

# Alpine (OpenRC)
sudo rc-service simple-kv status
sudo rc-service simple-kv restart
```

### 下载预编译二进制

从 [Releases](https://github.com/OWNER/simple-kv/releases) 下载与你的系统匹配的文件：

- `simple-kv_vX.Y.Z_linux_amd64.tar.gz` —— 适用于绝大多数 Linux（含 Alpine）

解压后直接运行：

```bash
tar -xzf simple-kv_vX.Y.Z_linux_amd64.tar.gz
./simple-kv
```

> 由于 `CGO_ENABLED=0` 构建出的二进制是**完全静态**的，同一份产物可在 glibc 与 musl 系统上运行。

### 从源码编译

```bash
git clone https://github.com/OWNER/simple-kv.git
cd simple-kv
go build -o simple-kv .
```

需要 Go 1.22 或更高版本。

## 配置（环境变量）

| 变量名 | 默认值 | 说明 |
|---|---|---|
| `KV_PORT` | `8080` | HTTP 监听端口 |
| `KV_DATA_DIR` | `./data` | 数据库文件存储目录 |
| `KV_AUTH_TOKEN` | 空（可选） | 若设置则启用 `Authorization: Bearer <token>` 鉴权 |

## API

所有接口返回 `Content-Type: text/plain; charset=utf-8`。

### `GET /{db}/{key}`
读取键值。
- `200` 返回值
- `404` 键不存在
- `400` 名称非法
- `401` 鉴权失败

### `PUT /{db}/{key}`
写入或覆盖键值，请求体为纯文本（≤ 50 KiB）。
- `200` 成功
- `400` 名称非法或请求体过大
- `401` 鉴权失败

### `DELETE /{db}/{key}`
删除键。
- `204` 成功
- `404` 键不存在
- `400` 名称非法
- `401` 鉴权失败

## 约束

- **数据库名 / 键**：仅小写字母和数字，长度 1–10
- **值**：纯文本，≤ 50 KiB
- **数据隔离**：每个 db 对应 `DATA_DIR/<db>.db`，首次访问自动创建

## 发布

本项目通过 GitHub Actions 在推送形如 `v*` 的 tag 时自动构建并发布：

```bash
git tag v0.1.0
git push origin v0.1.0
```

工作流将生成 `simple-kv_v0.1.0_linux_amd64.tar.gz` 与 `checksums.txt`，并创建对应的 GitHub Release。

> 第一次跑 Action 前，请确认仓库 Settings → Actions → Workflow permissions 已选择 **Read and write permissions**。

## License

MIT
