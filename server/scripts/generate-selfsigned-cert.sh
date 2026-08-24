#!/usr/bin/env bash
# 生成 IP 自签证书（无域名场景），供 Caddy 挂载与客户端证书绑定。
#
# 用法:
#   bash scripts/generate-selfsigned-cert.sh <服务器公网IP>
# 或从 .env 的 KMXZS_SERVER_IP 读取
set -euo pipefail

SERVER_IP="${1:-}"
if [[ -z "$SERVER_IP" ]]; then
  if [[ -f .env ]] && grep -q '^KMXZS_SERVER_IP=' .env; then
    SERVER_IP="$(grep '^KMXZS_SERVER_IP=' .env | head -n1 | cut -d= -f2- | tr -d '\r\" ')"
  fi
fi
if [[ -z "$SERVER_IP" ]]; then
  echo "用法: bash scripts/generate-selfsigned-cert.sh <服务器公网IP>" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
mkdir -p certs
CERT_DIR="$PWD/certs"

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/kmxzs-selfsigned.key" \
  -out "$CERT_DIR/kmxzs-selfsigned.crt" \
  -days 825 \
  -subj "/C=CN/O=kmxzs/CN=${SERVER_IP}" \
  -addext "subjectAltName=IP:${SERVER_IP}"

echo
echo "证书已生成:"
echo "  证书（PEM，客户端绑定用）: $CERT_DIR/kmxzs-selfsigned.crt"
echo "  私钥（仅服务器保存）:     $CERT_DIR/kmxzs-selfsigned.key"
echo
echo "客户端绑定指纹:"
bash scripts/export-cert-fingerprint.sh "$CERT_DIR/kmxzs-selfsigned.crt" || true
