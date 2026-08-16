# 补充：无域名 IP 部署与 HTTP 过渡说明

正式部署步骤见 [README.md](./README.md)。

## 端口与协议（阶段0 之后）

| 端口 | 协议 | 用途 |
|------|------|------|
| `18088` | HTTP | 老客户端 1.0.x 过渡入口，**仅放行** `/config`、`/files/*`、`/health` |
| `18443` | HTTPS | 新客户端 / 管理后台（IP 自签证书，客户端需证书绑定） |

- 老客户端连 `http://IP:18088`：仍能拿到更新提示（`/config`）并下载新版（`/files/latest.exe`），其余接口返回 403，推动用户升级到 HTTPS 新客户端。
- 新客户端连 `https://IP:18443`：完整功能；浏览器访问后台会提示自签证书，点“继续访问”。

## 安全建议

1. `.env`、`certs/kmxzs-selfsigned.key` 不要提交仓库、不要发给用户
2. `KMXZS_API_SECRET` 泄露 → 换新密钥并强制用户升级客户端
3. 卡密泄露 → 管理后台停用该卡
4. 管理 Token 只放自己电脑；后台尽量 SSH 隧道访问
5. 自签证书私钥仅服务器保存；客户端用导出的公钥/PEM 做证书绑定，防中间人

## 客户端防绕过（已实现）

HMAC 签名、nonce/时间窗（SQLite 持久化）、Release 禁用 localMock、周期在线验权、过期阻断一键开始、会话复核设备/过期。

## 阶段1 变更

- 新增 JWT 认证与分销代理子后台（`/api/auth`、`/api/admin`、`/api/reseller`）
- 限流与 nonce 从内存改为 SQLite 持久化（`rate_limits` / `nonce_seen` 表），重启不失效
- SQLite 开启 WAL，减少读写阻塞
