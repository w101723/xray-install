#!/usr/bin/env bash
set -euo pipefail

# Xray VLESS WebSocket config generator
#
# Default output:
#   $XRAY_CONFIG_DIR/10-vless-ws.json  (read from /etc/xray-install.conf)
#   /usr/local/etc/xray/10-vless-ws.json if the installer state file is absent
#
# File permissions:
#   root:<service-user-group> 0640 when the service user exists, so that
#   ExecStartPre / the xray service (which run as that user) can read it.
#
# Each run generates:
#   - random UUID
#   - random WebSocket path
#
# Transport uses "method": "websocket" (the field used by current official
# docs). Requires Xray >= v26.7.11; older releases only understand the legacy
# "network" field and would silently ignore "method". The installer's default
# "latest" resolves to a recent release, so this is satisfied by default.

OUTPUT="${1:-}"
LISTEN="127.0.0.1"
PORT=10000

# Follow the installer state so the file lands in the actual confdir.
SERVICE_USER="xray"
if [[ -z "$OUTPUT" && -r /etc/xray-install.conf ]]; then
  # shellcheck disable=SC1091
  . /etc/xray-install.conf
  [[ -n "${XRAY_CONFIG_DIR:-}" ]] && OUTPUT="$XRAY_CONFIG_DIR/10-vless-ws.json"
  [[ -n "${XRAY_INSTALL_USER:-}" ]] && SERVICE_USER="$XRAY_INSTALL_USER"
fi
OUTPUT="${OUTPUT:-/usr/local/etc/xray/10-vless-ws.json}"

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

# Make the file readable by the xray service user (it runs ExecStartPre and
# the main process). Only meaningful when running as root and the service
# user exists; otherwise the installer fixes it up on the next run.
SERVICE_GROUP=""
if id "$SERVICE_USER" >/dev/null 2>&1; then
  SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
fi

if [[ "$(id -u)" -eq 0 && -n "$SERVICE_GROUP" ]]; then
  chown "root:$SERVICE_GROUP" "$OUTPUT"
  chmod 0640 "$OUTPUT"
  PERMS_NOTE="perms:  root:$SERVICE_GROUP (0640)"
else
  PERMS_NOTE="perms:  0600 (will be fixed by the installer if needed)"
fi

echo
echo "Xray config generated successfully."
echo "file:   $OUTPUT"
echo "$PERMS_NOTE"
echo "listen: ${LISTEN}:${PORT}"
echo "uuid:   $UUID"
echo "path:   $WS_PATH"
echo
echo "Nginx proxy target: http://${LISTEN}:${PORT}"
