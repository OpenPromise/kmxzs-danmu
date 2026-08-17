#!/usr/bin/env bash
# Ubuntu 快速启动：在 server 目录执行  bash deploy.sh
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

HOST_PORT=18088
if grep -q '^KMXZS_HOST_PORT=' .env; then
  HOST_PORT="$(grep '^KMXZS_HOST_PORT=' .env | head -n1 | cut -d= -f2- | tr -d '\r" ' )"
  [[ -z "$HOST_PORT" ]] && HOST_PORT=18088
fi

docker compose up -d --build

echo
echo "等待健康检查..."
ok=0
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${HOST_PORT}/health" >/dev/null 2>&1; then
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
curl -sS "http://127.0.0.1:${HOST_PORT}/health" || true
echo
echo
echo "后台路径: /zbpanel/   （可用 KMXZS_ADMIN_PATH 修改）"
echo "后台账号: zbxzs       （可用 KMXZS_ADMIN_USER 修改）"
echo "后台密码:"
docker exec kmxzs-card-server cat /data/admin_basic.txt
echo
echo "后台: http://服务器IP:${HOST_PORT}/zbpanel/  （浏览器会弹出账号密码）"
