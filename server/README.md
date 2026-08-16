# kmxzs 卡密服务（Docker / Ubuntu）

HTTP 卡密授权服务，适合 **只有公网 IP、无域名** 的 Ubuntu 机器。

## 目录

| 文件 | 用途 |
|------|------|
| `Dockerfile` | 镜像 |
| `docker-compose.yml` | **Ubuntu 生产**（默认） |
| `docker-compose.dev.yml` | 本机联调（演示卡） |
| `.env.example` | 环境变量模板 → 复制为 `.env` |
| `deploy.sh` | Ubuntu 一键生成密钥并启动 |
| `app/` | FastAPI 源码 + 管理后台静态页 |

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
bash deploy.sh
```

脚本会生成 `.env` 与 `KMXZS_API_SECRET` 并打印出来——**请立刻保存，客户端编译要用同一密钥**。

### 或手动

```bash
cp .env.example .env
# 编辑 .env，KMXZS_API_SECRET= 填入 $(openssl rand -hex 32)
docker compose up -d --build
curl http://127.0.0.1:18088/health
docker exec -it kmxzs-card-server cat /data/admin_token.txt
```

```bash
# 查看日志
docker logs kmxzs-card-server
```

- 管理后台：`http://服务器IP:18088/zbpanel/`（路径可用 `KMXZS_ADMIN_PATH` 修改，不要用 `/admin`）
  - 浏览器会弹出账号密码（默认用户 `zbxzs`，可用 `KMXZS_ADMIN_USER` 修改）
  - 密码：`docker exec -it kmxzs-card-server cat /data/admin_basic.txt`
  - 只把地址、账号、密码私下发给合作伙伴；扫常见 `/admin` 进不去
  - 首页 `/` 不再跳转到后台
  - 客户端安装包：后台「客户端配置」可上传 `.exe`，用户下载地址为 `http://服务器IP:18088/files/latest.exe`

## 常用运维

```bash
docker compose ps
docker compose logs -f --tail=100
docker compose restart
docker compose pull   # 若改用远程镜像时
docker compose up -d --build   # 改代码后重建
```

数据在 Docker volume `kmxzs_card_data`（卡密库、admin token、后台密码），删容器不会丢；若要清空：

```bash
docker compose down -v   # 危险：删除全部卡密数据
```

## 与客户端对齐

客户端编译时必须使用 **同一** `KMXZS_API_SECRET`：

```bash
flutter build windows --release --obfuscate --split-debug-info=build/debug-info \
  --dart-define=KMXZS_API_BASE=http://你的服务器IP:18088 \
  --dart-define=KMXZS_API_SECRET=与.env里相同的值
```

也可在 exe 旁放 `kmxzs.config.json` 只改 IP（密钥仍须编译进包）。

## 生产默认行为

- `KMXZS_SEED_DEMO=0`：无演示卡
- `KMXZS_PRODUCTION=1`：弱化 `/health` 信息、缩短 admin token 日志
- `KMXZS_REQUIRE_SIGN=1`：强制客户端 HMAC 签名
- CORS 默认关闭

## 本机 Windows 联调

```bash
docker compose -f docker-compose.dev.yml up -d --build
```

开发模式会种演示卡，且不强制签名。
