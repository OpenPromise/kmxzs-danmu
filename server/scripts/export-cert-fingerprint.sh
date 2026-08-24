#!/usr/bin/env bash
# 导出证书的 SHA-256 指纹与 PEM，供 Flutter 客户端证书绑定（pinning）。
#
# 用法: bash scripts/export-cert-fingerprint.sh [cert.pem]
set -euo pipefail

CERT="${1:-certs/kmxzs-selfsigned.crt}"
if [[ ! -f "$CERT" ]]; then
  echo "证书不存在: $CERT（先用 scripts/generate-selfsigned-cert.sh 生成）" >&2
  exit 1
fi

echo "== SHA-256 指纹（DER, base64，常用于 sha256 绑定）=="
openssl x509 -in "$CERT" -outform der | openssl dgst -sha256 -binary | base64 -w0
echo
echo "== SHA-256 指纹（hex）=="
openssl x509 -in "$CERT" -outform der | openssl dgst -sha256 | awk '{print $2}'
echo
echo "== PEM 证书内容（可内嵌到客户端资源）=="
cat "$CERT"
