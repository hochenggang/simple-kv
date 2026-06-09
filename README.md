# simple-kv

一个极简的 HTTP Key-Value 存储服务，基于 Go + SQLite（WAL 模式），适合作为 CDN 回源的轻量后端。

## 特性

- 纯 Go 实现，无 CGO 依赖，**单一静态二进制**即可在 glibc 与 musl（Alpine）系统上运行
- SQLite WAL 模式，单 DB 文件落盘，支持多数据库名隔离
- 仅暴露 HTTP 端口，可直接被 CDN 回源调用
- 可选 Bearer Token 鉴权（`KV_AUTH_TOKEN` 环境变量）
- 严格的输入校验：db / key 仅允许小写字母与数字，长度 1–10
- value 限制为 50 KiB 纯文本



### 下载预编译二进制

从 [Releases](https://github.com/OWNER/simple-kv/releases) 下载与你的系统匹配的文件：

- `simple-kv_vX.Y.Z_linux_amd64` —— 适用于绝大多数 Linux（含 Alpine）

直接运行：

```bash
chmod +x simple-kv_vX.Y.Z_linux_amd64
./simple-kv_vX.Y.Z_linux_amd64
```

> 由于 `CGO_ENABLED=0` 构建出的二进制是**完全静态**的，同一份产物可在 glibc 与 musl 系统上运行。


## 配置（环境变量）

| 变量名 | 默认值 | 说明 |
|---|---|---|
| `KV_HOST` | `0.0.0.0` | 监听地址；设成 `127.0.0.1` 仅对内网暴露 |
| `KV_PORT` | `8080` | HTTP 监听端口 |
| `KV_DATA_DIR` | `./data` | 数据库文件存储目录 |
| `KV_AUTH_TOKEN` | 空（可选） | 若设置则启用 `Authorization: Bearer <token>` 鉴权 |

## API



## 快速开始

```bash
# 写
curl -X PUT -d "hello world" http://localhost:8080/mydb/mykey -H "Authorization: Bearer <token>"

# 读
curl http://localhost:8080/mydb/mykey -H "Authorization: Bearer <token>"
# -> hello world

# 删
curl -X DELETE http://localhost:8080/mydb/mykey -H "Authorization: Bearer <token>"
```

所有接口返回 `Content-Type: text/plain; charset=utf-8`。

所有响应携带 CORS 头（`Access-Control-Allow-Origin: *`，允许 `GET / PUT / DELETE / OPTIONS`），浏览器跨域可直接调用；预检 `OPTIONS` 请求会直接以 `204` 短路返回，不会走到鉴权。

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

工作流将生成 `simple-kv_v0.1.0_linux_amd64` 与 `checksums.txt`，并创建对应的 GitHub Release。

## License

MIT
