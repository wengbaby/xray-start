#!/usr/bin/env bash
set -e

APP_DIR="$HOME/xray-node"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

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

# 地址：优先使用面板注入的 SERVER_IP
PUBLIC_HOST="${SERVER_IP:-}"

# 如果 SERVER_IP 不存在，则尝试获取公网 IPv4
if [ -z "$PUBLIC_HOST" ]; then
  if command -v curl >/dev/null 2>&1; then
    PUBLIC_HOST="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
  elif command -v wget >/dev/null 2>&1; then
    PUBLIC_HOST="$(wget -qO- -T 5 https://api.ipify.org || true)"
  fi
fi

if [ -z "$PUBLIC_HOST" ]; then
  echo "ERROR: Public IP not found."
  echo "Please check SERVER_IP or network access."
  echo "Run this command to inspect:"
  echo "env | sort | grep -Ei 'server|port|ip|allocation|host|node'"
  exit 1
fi

# ==============================
# 2. UUID
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
# 3. 下载 Xray-core
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
    unzip -o xray.zip
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e xray.zip .
  elif command -v python >/dev/null 2>&1; then
    python -m zipfile -e xray.zip .
  else
    echo "ERROR: unzip, python3 or python is required to extract xray.zip."
    exit 1
  fi

  chmod +x xray
fi

# ==============================
# 4. 生成 Xray 配置
# ==============================

cat > config.json <<JSON
{
  "log": {
    "loglevel": "warning"
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
# 5. 输出节点信息
# ==============================

VLESS_LINK="vless://${UUID}@${PUBLIC_HOST}:${PORT}?type=ws&security=none&path=%2Fvless#lunes-vless-ws"

clear 2>/dev/null || true

echo "============================================================"
echo " Xray VLESS WebSocket node is ready"
echo "============================================================"
echo "Address: ${PUBLIC_HOST}"
echo "Port: ${PORT}"
echo "UUID: ${UUID}"
echo "Protocol: VLESS"
echo "Transport: WebSocket"
echo "WS Path: /vless"
echo "TLS: none"
echo "Security: none"
echo ""
echo "v2rayN node link:"
echo "${VLESS_LINK}"
echo "============================================================"
echo ""
echo "Starting Xray..."
echo ""

# ==============================
# 6. 启动 Xray
# ==============================

exec "$XRAY_BIN" run -config "$APP_DIR/config.json"
