#!/usr/bin/env bash
# 自签 TLS 证书一键生成（测试/内网用）。生产环境请用 certbot/Let's Encrypt。
# 用法：bash deploy/gen-selfsigned.sh [域名]   （缺省 relay.local）
set -euo pipefail

DOMAIN="${1:-relay.local}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS="$HERE/certs"
mkdir -p "$CERTS"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$CERTS/privkey.pem" -out "$CERTS/fullchain.pem" \
  -days 825 -nodes -subj "/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN" >/dev/null 2>&1

chmod 600 "$CERTS/privkey.pem"
echo "✅ 自签证书已生成：$CERTS/fullchain.pem（CN=$DOMAIN，825 天）"
echo "   手机浏览器会提示不受信任——测试可接受，生产请换真证书。"
