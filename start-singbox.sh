#!/usr/bin/env bash
set -e

APP_DIR="$HOME/singbox-node"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# ==============================
# 0. 启动参数
# ==============================

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

if [ -z "${SERVER_PORT:-}" ]; then
  echo "ERROR: SERVER_PORT not found."
  echo "Run:"
  echo "env | sort | grep -Ei 'server|port|ip|allocation|host|node'"
  exit 1
fi

PORT="${SERVER_PORT}"
PUBLIC_IP="${SERVER_IP:-}"

if [ -z "$PUBLIC_IP" ]; then
  if command -v curl >/dev/null 2>&1; then
    PUBLIC_IP="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
  elif command -v wget >/dev/null 2>&1; then
    PUBLIC_IP="$(wget -qO- -T 5 https://api.ipify.org || true)"
  fi
fi

if [ -z "$PUBLIC_IP" ]; then
  echo "ERROR: Public IP not found."
  exit 1
fi

PUBLIC_HOST="${DNS_NAME}"

# ==============================
# 2. Cloudflare DNS 自动更新，可选
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
      CF_DNS_STATUS="failed"
    fi
  fi
else
  echo "CloudflareToken or ZoneID not provided, skip Cloudflare DNS update."
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
# 4. 下载 sing-box
# ==============================

SING_BOX_BIN="$APP_DIR/sing-box"

if [ ! -f "$SING_BOX_BIN" ]; then
  echo "Downloading sing-box..."

  VERSION="$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)"

  if [ -z "$VERSION" ]; then
    echo "ERROR: failed to get latest sing-box version."
    exit 1
  fi

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64)
      SB_ARCH="linux-amd64"
      ;;
    aarch64|arm64)
      SB_ARCH="linux-arm64"
      ;;
    *)
      echo "Unsupported architecture: $ARCH"
      exit 1
      ;;
  esac

  TARBALL="sing-box-${VERSION}-${SB_ARCH}.tar.gz"
  URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${TARBALL}"

  rm -f "$TARBALL"
  if command -v curl >/dev/null 2>&1; then
    curl -L -o "$TARBALL" "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$TARBALL" "$URL"
  else
    echo "ERROR: curl or wget is required."
    exit 1
  fi

  tar -xzf "$TARBALL"

  FOUND_BIN="$(find "$APP_DIR" -type f -name sing-box | head -n 1)"
  if [ -z "$FOUND_BIN" ]; then
    echo "ERROR: sing-box binary not found after extract."
    exit 1
  fi

  cp "$FOUND_BIN" "$SING_BOX_BIN"
  chmod +x "$SING_BOX_BIN"
fi

# ==============================
# 5. 生成 sing-box 配置
# ==============================

cat > config.json <<JSON
{
  "log": {
    "disabled": true,
    "level": "fatal",
    "timestamp": false
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
JSON

# ==============================
# 6. 输出节点信息
# ==============================

VLESS_LINK="vless://${UUID}@${PUBLIC_HOST}:${PORT}?type=ws&security=none&path=%2Fvless#${NODE_NAME_ENCODED}"
VLESS_IP_LINK="vless://${UUID}@${PUBLIC_IP}:${PORT}?type=ws&security=none&path=%2Fvless#${NODE_NAME_ENCODED}-IP"

clear 2>/dev/null || true

echo "============================================================"
echo " sing-box VLESS WebSocket node is ready"
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
echo ""
echo "IP test link:"
echo "${VLESS_IP_LINK}"
echo "============================================================"
echo ""
echo "Starting sing-box in quiet mode..."
echo ""

# ==============================
# 7. 启动 sing-box 静默模式
# ==============================

exec "$SING_BOX_BIN" run -c "$APP_DIR/config.json" >/dev/null 2>&1
