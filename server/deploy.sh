#!/usr/bin/env bash
# Ubuntu 快速启动：在 server 目录执行  bash deploy.sh [服务器公网IP]
# 会生成 .env、自签证书并启动 Caddy + FastAPI。
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v docker >/dev/null 2>&1; then
  echo "未检测到 docker，请先: sudo apt install -y docker.io docker-compose-v2"
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "未检测到 docker compose 插件，请安装 docker-compose-v2"
  exit 1
fi

SERVER_IP="${1:-}"

if [[ ! -f .env ]]; then
  cp .env.example .env
  SECRET="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  if grep -q '^KMXZS_API_SECRET=' .env; then
    sed -i "s|^KMXZS_API_SECRET=.*|KMXZS_API_SECRET=${SECRET}|" .env
  else
    echo "KMXZS_API_SECRET=${SECRET}" >> .env
  fi
  echo "已生成 .env"
  echo "请保存此密钥用于客户端编译:"
  echo "  KMXZS_API_SECRET=${SECRET}"
fi

# 若传了 IP 或 .env 里配置了 KMXZS_SERVER_IP，自动生成自签证书
if [[ -z "$SERVER_IP" ]] && grep -q '^KMXZS_SERVER_IP=' .env; then
  SERVER_IP="$(grep '^KMXZS_SERVER_IP=' .env | head -n1 | cut -d= -f2- | tr -d '\r\" ')"
fi
if [[ -n "$SERVER_IP" ]]; then
  if [[ ! -f certs/kmxzs-selfsigned.crt ]]; then
    echo "生成自签证书（IP: ${SERVER_IP}）..."
    bash scripts/generate-selfsigned-cert.sh "$SERVER_IP"
  else
    echo "自签证书已存在，跳过生成"
  fi
else
  echo "未提供服务器 IP，跳过证书生成。可稍后运行:"
  echo "  bash scripts/generate-selfsigned-cert.sh <服务器IP>"
fi

docker compose up -d --build

echo
echo "等待健康检查..."
ok=0
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${KMXZS_HTTP_PORT:-18088}/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done

if [[ "$ok" -ne 1 ]]; then
  echo "健康检查失败，请查看: docker compose logs --tail=80"
  exit 1
fi

echo "健康检查通过:"
curl -sS "http://127.0.0.1:${KMXZS_HTTP_PORT:-18088}/health" || true
echo
echo
echo "后台路径: /zbpanel/   （可用 KMXZS_ADMIN_PATH 修改）"
echo "后台账号: zbxzs       （可用 KMXZS_ADMIN_USER 修改）"
echo "后台密码:"
docker exec kmxzs-card-server cat /data/admin_basic.txt
echo
echo "超管(分销代理后台):"
docker exec kmxzs-card-server cat /data/superadmin.txt 2>/dev/null || echo "  （由 KMXZS_SUPERADMIN_USER/PASSWORD 指定，未设置则见 /data/superadmin.txt）"
echo
echo "HTTP 过渡入口（老客户端）: http://服务器IP:${KMXZS_HTTP_PORT:-18088}"
echo "HTTPS 入口（新客户端/后台）: https://服务器IP:${KMXZS_HTTPS_PORT:-18443}"
echo "管理 SPA: https://服务器IP:${KMXZS_HTTPS_PORT:-18443}/panel/   （需先构建 admin-web/dist，见 README 阶段2）"
echo "旧后台(过渡): https://服务器IP:${KMXZS_HTTPS_PORT:-18443}/zbpanel/"
