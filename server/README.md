# kmxzs 卡密服务（Docker / Ubuntu）

HTTPS 卡密授权服务，适合 **只有公网 IP、无域名** 的 Ubuntu 机器。
Caddy 反代终止 TLS（IP 自签证书），HTTP `:18088` 作为老客户端过渡入口。

## 目录

| 文件 | 用途 |
|------|------|
| `Dockerfile` | 镜像（启动前自动 `alembic upgrade head`） |
| `docker-compose.yml` | **Ubuntu 生产**：Caddy + FastAPI |
| `docker-compose.dev.yml` | 本机联调（演示卡，无 Caddy） |
| `caddy/Caddyfile` | 反向代理配置（HTTPS :18443 / HTTP :18088） |
| `scripts/generate-selfsigned-cert.sh` | 生成 IP 自签证书 |
| `scripts/export-cert-fingerprint.sh` | 导出证书指纹/PEM 供客户端绑定 |
| `.env.example` | 环境变量模板 → 复制为 `.env` |
| `deploy.sh` | Ubuntu 一键生成密钥/证书并启动 |
| `app/` | FastAPI 分层源码（core/models/schemas/services/api） |
| `alembic/` | 数据库迁移（基线 + 阶段1 新表） |
| `tests/` | pytest 关键路径测试 |

## Ubuntu 一键部署（推荐）

```bash
# 1) 安装 Docker
sudo apt update
sudo apt install -y docker.io docker-compose-v2 curl
sudo systemctl enable --now docker
# 若当前用户不在 docker 组：sudo usermod -aG docker $USER && newgrp docker

# 2) 上传本 server 目录，例如 /opt/kmxzs-server
cd /opt/kmxzs-server
chmod +x deploy.sh
bash deploy.sh <你的服务器公网IP>
```

脚本会生成 `.env`、IP 自签证书，并打印 `KMXZS_API_SECRET`——**请立刻保存，客户端编译要用同一密钥**。

### 或手动

```bash
cp .env.example .env
# 编辑 .env：KMXZS_API_SECRET=$(openssl rand -hex 32)，建议同时填 KMXZS_SERVER_IP
bash scripts/generate-selfsigned-cert.sh <服务器公网IP>   # 生成 certs/
docker compose up -d --build
curl -k https://127.0.0.1:18443/health
docker exec -it kmxzs-card-server cat /data/admin_token.txt
```

```bash
# 查看日志
docker logs kmxzs-card-server
docker logs kmxzs-caddy
```

- 管理后台：`https://服务器IP:18443/zbpanel/`（路径可用 `KMXZS_ADMIN_PATH` 修改）
  - 浏览器会提示证书不受信任（自签），点“继续访问”即可
  - 账号默认 `zbxzs`，密码：`docker exec -it kmxzs-card-server cat /data/admin_basic.txt`
  - 阶段1 超管（分销代理后台）：`docker exec -it kmxzs-card-server cat /data/superadmin.txt`
- 客户端安装包：后台「客户端配置」可上传 `.exe`，下载地址 `https://IP:18443/files/latest.exe`
- **HTTP 过渡入口** `http://IP:18088` 仅放行 `/config`、`/files/*`、`/health`，老客户端 1.0.x 仍可收到更新提示并下载新版；其余路径返回 403 推动升级

## 阶段1：分销代理基础版

- `POST /api/auth/login`：superadmin / reseller 登录（JWT access+refresh）
- 超管接口 `/api/admin/*`：渠道与代理管理（建渠道、建代理、配发卡配额、启停）
- 代理接口 `/api/reseller/*`：仅管理自己渠道下的卡密/账号/设备，发卡受 `card_quota` 限制
- 所有管理/代理操作写入 `audit_logs`，`actor` 为用户名，`detail.role` 为角色
- 首次启动自动创建超管（`KMXZS_SUPERADMIN_USER` / `KMXZS_SUPERADMIN_PASSWORD`，密码留空则生成到 `/data/superadmin.txt`）

## 阶段2：管理 SPA（`admin-web/`）

React 18 + TypeScript + Vite + Ant Design v5 + ProComponents，走 JWT 接口，按角色渲染：

- 超管：数据总览、卡密管理（筛选/复制/停用/删除/导出/发卡）、账号续期、设备解绑、渠道/代理管理、审计日志、客户端配置、安装包发布
- 代理：仅自己渠道的数据总览、配额内发卡、卡密/账号/设备管理、操作日志
- 构建产物 `admin-web/dist` 由 Caddy 托管在 `https://IP:18443/panel/`（history 路由回退 index.html），`/api/*` 继续反代到后端
- 旧后台 `https://IP:18443/zbpanel/` 继续保留，过渡期仍可用

本地开发：

```bash
# 后端（server 目录）
python -m venv .venv && .venv/Scripts/activate  # 首次
.venv/Scripts/python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 18080

# 前端（admin-web 目录）
npm install
npm run dev          # http://localhost:5173/panel/，/api 代理到 127.0.0.1:18080
```

生产部署（构建 SPA 后启动 compose）：

```bash
cd ../admin-web && npm ci && npm run build   # 产物输出到 admin-web/dist
cd ../server
bash deploy.sh <服务器公网IP>
# 管理后台: https://IP:18443/panel/（SPA） 与 https://IP:18443/zbpanel/（旧后台过渡）
```

> 若本地后端不在 18080，可在 `admin-web/.env.local` 里写 `VITE_DEV_PROXY_TARGET=http://127.0.0.1:<端口>` 覆盖 dev 代理目标。

## 证书导出（客户端证书绑定）

```bash
cd /opt/kmxzs-server
bash scripts/export-cert-fingerprint.sh certs/kmxzs-selfsigned.crt
```

输出 SHA-256 指纹（base64 与 hex）及 PEM 内容，供 Flutter 客户端编译期内嵌做 pinning。

## 数据库迁移

启动容器时会自动执行 `alembic upgrade head`（幂等）。若需在已有库上手动升级：

```bash
docker exec -it kmxzs-card-server sh -c "cd /app && alembic stamp 0001 && alembic upgrade head"
```

- 新库：`alembic upgrade head` 全量建表
- 旧库：`stamp 0001` 标记现有基线后 `upgrade head` 新增 users/channels/cards.channel_id，不丢数据

## 常用运维

```bash
docker compose ps
docker compose logs -f --tail=100
docker compose restart
docker compose up -d --build   # 改代码后重建
```

数据在 Docker volume `kmxzs_card_data`（卡密库、admin token、后台密码、超管密码、JWT 密钥），删容器不会丢；若要清空：

```bash
docker compose down -v   # 危险：删除全部卡密数据
```

## 与客户端对齐

客户端编译时必须使用 **同一** `KMXZS_API_SECRET`：

```bash
flutter build windows --release --obfuscate --split-debug-info=build/debug-info \
  --dart-define=KMXZS_API_BASE=https://你的服务器IP:18443 \
  --dart-define=KMXZS_API_SECRET=与.env里相同的值
```

也可在 exe 旁放 `kmxzs.config.json` 只改 IP（密钥仍须编译进包）。

## 生产默认行为

- `KMXZS_SEED_DEMO=0`：无演示卡
- `KMXZS_PRODUCTION=1`：弱化 `/health` 信息
- `KMXZS_REQUIRE_SIGN=1`：强制客户端 HMAC 签名
- `KMXZS_TRUST_PROXY=1`：信任 Caddy 反代头（限流按真实 IP）
- `KMXZS_HTTP_TRANSITION=1`：明文 HTTP 只放行过渡白名单
- CORS 默认关闭

## 本机 Windows 联调

```bash
docker compose -f docker-compose.dev.yml up -d --build
```

开发模式会种演示卡，且不强制签名、无 Caddy（保持原有 HTTP 行为）。
