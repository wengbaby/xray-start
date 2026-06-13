#!/usr/bin/env bash
set -e

APP_DIR="$HOME/xray-node"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# ==============================
# 0. 启动参数
# ==============================

# 用法：
# bash start.sh
# bash start.sh 7
# bash start.sh 7 CloudflareToken CloudflareZoneID
#
# 参数 1：节点编号，可选
#        不填 => us.totapp.com / US-TOTAPP.COM
#        填 7 => us7.totapp.com / US7-TOTAPP.COM
#
# 参数 2：Cloudflare API Token，可选
# 参数 3：Cloudflare Zone ID，可选
#
# 如果不传 CloudflareToken 和 ZoneID：
# - 不更新 Cloudflare
# - 节点链接仍然使用域名
#
# 如果传了 CloudflareToken 和 ZoneID：
# - 自动更新 us数字.totapp.com 的 A 记录
# - 节点链接使用 us数字.totapp.com

NODE_NUM="${1:-}"
CF_TOKEN="${2:-${CF_API_TOKEN:-}}"
CF_ZONE_ID="${3:-${CF_ZONE_ID:-}}"

ROOT_DOMAIN="totapp.com"

if [ -n "$NODE_NUM" ]; then
  NODE_NAME="US${NODE_NUM}-TOTAPP.COM"
  DNS_NAME="us${NODE_NUM}.${ROOT_DOMAIN}"
else
  NODE_NAME="US-TOTAPP.COM"
  DNS_NAME="us.${ROOT_DOMAIN}"
fi

NODE_NAME_ENCODED="$(printf '%s' "$NODE_NAME" | sed 's/ /%20/g')"

# ==============================
# 1. 自动获取地址和端口
# ==============================

# 端口：必须使用面板注入的 SERVER_PORT
if [ -z "${SERVER_PORT:-}" ]; then
  echo "ERROR: SERVER_PORT not found."
  echo "Please check panel environment variables."
  echo "Run this command to inspect:"
  echo "env | sort | grep -Ei 'server|port|ip|allocation|host|node'"
  exit 1
fi

PORT="${SERVER_PORT}"

# IP：优先使用面板注入的 SERVER_IP
PUBLIC_IP="${SERVER_IP:-}"

# 如果 SERVER_IP 不存在，则尝试获取公网 IPv4
if [ -z "$PUBLIC_IP" ]; then
  if command -v curl >/dev/null 2>&1; then
    PUBLIC_IP="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
  elif command -v wget >/dev/null 2>&1; then
    PUBLIC_IP="$(wget -qO- -T 5 https://api.ipify.org || true)"
  fi
fi

if [ -z "$PUBLIC_IP" ]; then
  echo "ERROR: Public IP not found."
  echo "Please check SERVER_IP or network access."
  echo "Run this command to inspect:"
  echo "env | sort | grep -Ei 'server|port|ip|allocation|host|node'"
  exit 1
fi

# vless 链接始终使用域名，不使用 IP
PUBLIC_HOST="${DNS_NAME}"

# ==============================
# 2. Cloudflare DNS 自动更新
# ==============================

CF_DNS_STATUS="skipped"

if [ -n "$CF_TOKEN" ] && [ -n "$CF_ZONE_ID" ]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "WARNING: curl not found, skip Cloudflare DNS update."
    CF_DNS_STATUS="skipped: curl not found"
  else
    echo "Updating Cloudflare DNS: ${DNS_NAME} -> ${PUBLIC_IP}"

    RECORD_ID="$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${DNS_NAME}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" \
      | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1)"

    if [ -n "$RECORD_ID" ]; then
      CF_RESULT="$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${DNS_NAME}\",\"content\":\"${PUBLIC_IP}\",\"ttl\":60,\"proxied\":false}")"
    else
      CF_RESULT="$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${DNS_NAME}\",\"content\":\"${PUBLIC_IP}\",\"ttl\":60,\"proxied\":false}")"
    fi

    if echo "$CF_RESULT" | grep -q '"success":true'; then
      echo "Cloudflare DNS updated successfully."
      CF_DNS_STATUS="updated"
    else
      echo "WARNING: Cloudflare DNS update failed."
      echo "$CF_RESULT"
      echo "Continue with domain address: ${DNS_NAME}"
      CF_DNS_STATUS="failed"
    fi
  fi
else
  echo "CloudflareToken or ZoneID not provided, skip Cloudflare DNS update."
  echo "Using domain address in node link: ${DNS_NAME}"
fi

# ==============================
# 3. UUID
# ==============================

UUID_FILE="$APP_DIR/uuid.txt"

if [ ! -f "$UUID_FILE" ]; then
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen > "$UUID_FILE"
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid > "$UUID_FILE"
  else
    cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/' > "$UUID_FILE"
  fi
fi

UUID="$(cat "$UUID_FILE")"

# ==============================
# 4. 下载 Xray-core
# ==============================

XRAY_BIN="$APP_DIR/xray"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64|amd64)
    XRAY_ZIP="Xray-linux-64.zip"
    ;;
  aarch64|arm64)
    XRAY_ZIP="Xray-linux-arm64-v8a.zip"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

if [ ! -f "$XRAY_BIN" ]; then
  echo "Downloading Xray-core..."
  rm -f xray.zip

  if command -v curl >/dev/null 2>&1; then
    curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ZIP}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ZIP}"
  else
    echo "ERROR: curl or wget is required."
    exit 1
  fi

  if command -v unzip >/dev/null 2>&1; then
    unzip -o xray.zip >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e xray.zip . >/dev/null 2>&1
  elif command -v python >/dev/null 2>&1; then
    python -m zipfile -e xray.zip . >/dev/null 2>&1
  else
    echo "ERROR: unzip, python3 or python is required to extract xray.zip."
    exit 1
  fi

  chmod +x xray
fi

# ==============================
# 5. 生成 Xray 配置
# ==============================

cat > config.json <<JSON
{
  "log": {
    "access": "none",
    "error": "none",
    "loglevel": "none"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/vless"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
JSON

# ==============================
# 6. 输出节点信息
# ==============================

VLESS_LINK="vless://${UUID}@${PUBLIC_HOST}:${PORT}?type=ws&security=none&path=%2Fvless#${NODE_NAME_ENCODED}"

clear 2>/dev/null || true

echo "============================================================"
echo " Xray VLESS WebSocket node is ready"
echo "============================================================"
echo "Node Name: ${NODE_NAME}"
echo "Server IP: ${PUBLIC_IP}"
echo "Address: ${PUBLIC_HOST}"
echo "Port: ${PORT}"
echo "UUID: ${UUID}"
echo "Protocol: VLESS"
echo "Transport: WebSocket"
echo "WS Path: /vless"
echo "TLS: none"
echo "Security: none"
echo "Cloudflare DNS: ${CF_DNS_STATUS}"
echo "DNS Name: ${DNS_NAME}"
echo ""
echo "v2rayN node link:"
echo "${VLESS_LINK}"
echo "============================================================"
echo ""
echo "Starting Xray in quiet mode..."
echo ""

# ==============================
# 7. 启动 Xray 静默模式
# ==============================

exec "$XRAY_BIN" run -config "$APP_DIR/config.json" >/dev/null 2>&1
