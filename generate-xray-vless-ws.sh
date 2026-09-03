#!/usr/bin/env bash
set -euo pipefail

# Xray VLESS WebSocket config generator
#
# Default:
#   listen: 127.0.0.1
#   port:   10000
#   output: /usr/local/etc/xray/10-vless-ws.json
#
# Each run generates:
#   - random UUID
#   - random WebSocket path

OUTPUT="${1:-/usr/local/etc/xray/10-vless-ws.json}"
LISTEN="127.0.0.1"
PORT=10000

if [[ "$(id -u)" -ne 0 ]] && [[ "$OUTPUT" == /usr/local/* || "$OUTPUT" == /etc/* ]]; then
  echo "error: writing to $OUTPUT requires root." >&2
  echo "usage: sudo $0 [output-file]" >&2
  exit 1
fi

generate_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    echo "error: cannot generate UUID (/proc/sys/kernel/random/uuid and uuidgen unavailable)." >&2
    exit 1
  fi
}

generate_path() {
  local random_hex
  random_hex="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  printf '/%s\n' "$random_hex"
}

UUID="$(generate_uuid)"
WS_PATH="$(generate_path)"

mkdir -p "$(dirname "$OUTPUT")"

if [[ -e "$OUTPUT" ]]; then
  BACKUP="${OUTPUT}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$OUTPUT" "$BACKUP"
  echo "backup: $BACKUP"
fi

cat >"$OUTPUT" <<EOF
{
  "log": {
    "loglevel": "error"
  },
  "inbounds": [
    {
      "tag": "vless-ws-in",
      "listen": "${LISTEN}",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "users": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "method": "websocket",
        "security": "none",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ]
}
EOF

chmod 600 "$OUTPUT"

echo
echo "Xray config generated successfully."
echo "file:   $OUTPUT"
echo "listen: ${LISTEN}:${PORT}"
echo "uuid:   $UUID"
echo "path:   $WS_PATH"
echo
echo "Nginx proxy target: http://${LISTEN}:${PORT}"
