#!/usr/bin/env bash
#
# Xray production installer (systemd + multi-config directory)
# Based on the deployment layout used by XTLS/Xray-install.
#
# Features:
#   - Install/upgrade latest Xray-core release
#   - Install/upgrade a specified Xray-core version
#   - Always run Xray with a customizable multi-config directory (-confdir)
#   - Generate a production-friendly systemd service
#   - SHA256 verification using the official .dgst file
#   - Config test before restart
#   - Binary/service rollback when an upgrade fails
#
set -Eeuo pipefail

PROGRAM_NAME="$(basename "$0")"
XRAY_BIN="/usr/local/bin/xray"
ASSET_DIR="/usr/local/share/xray"
STATE_FILE="/etc/xray-install.conf"
SERVICE_FILE="/etc/systemd/system/xray.service"
SERVICE_NAME="xray.service"
LOG_DIR="/var/log/xray"

ACTION="install"
TARGET_VERSION="latest"
CONFIG_DIR="/usr/local/etc/xray"
INSTALL_USER="xray"
PROXY=""
WITH_GEODATA=1
PRERELEASE=0
FORCE=0

TMP_DIR=""
OLD_VERSION=""
NEW_VERSION=""
BINARY_BACKUP=""
SERVICE_BACKUP=""
HAD_OLD_BINARY=0
HAD_OLD_SERVICE=0

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage:
  xray-install-production.sh install [options]
  xray-install-production.sh upgrade [options]
  xray-install-production.sh service [options]
  xray-install-production.sh status

Actions:
  install     Install Xray. If already installed, it also behaves as an upgrade.
  upgrade     Upgrade/downgrade Xray to latest or a specified version.
  service     Only regenerate/reload the systemd service; do not download Xray.
  status      Show Xray version and systemd status.

Options:
  --version <latest|VERSION>   Target version. Examples: latest, v26.3.27, 26.3.27
  --config-dir <DIR>           Multi-config directory used by "xray run -confdir".
                               Default: /usr/local/etc/xray
  --user <USER>                systemd service user. Default: xray
  --proxy <URL>                curl proxy, e.g. socks5h://127.0.0.1:1080
  --without-geodata            Do not install/update geoip.dat and geosite.dat
  --prerelease                 Resolve "latest" to the newest release including
                               pre-releases (upstream marks recent Xray releases
                               as pre-release, so default "latest" can lag behind)
  --force                      Reinstall even when the target version is current
  -h, --help                   Show this help

Examples:
  # Latest version + default multi-config directory
  sudo ./xray-install-production.sh install

  # Latest version + custom multi-config directory
  sudo ./xray-install-production.sh install --config-dir /etc/xray/conf.d

  # Upgrade to latest; remembers previous config directory/user
  sudo ./xray-install-production.sh upgrade

  # Install/upgrade/downgrade to a specified version
  sudo ./xray-install-production.sh upgrade --version v26.3.27

  # Only rewrite systemd service to use a new config directory
  sudo ./xray-install-production.sh service --config-dir /etc/xray/conf.d
USAGE
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Please run as root."
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 0

  # shellcheck disable=SC1090
  source "$STATE_FILE"

  CONFIG_DIR="${XRAY_CONFIG_DIR:-$CONFIG_DIR}"
  INSTALL_USER="${XRAY_INSTALL_USER:-$INSTALL_USER}"
  WITH_GEODATA="${XRAY_WITH_GEODATA:-$WITH_GEODATA}"
}

save_state() {
  umask 077
  cat >"$STATE_FILE" <<EOF_STATE
# Managed by $PROGRAM_NAME
XRAY_CONFIG_DIR=$(printf '%q' "$CONFIG_DIR")
XRAY_INSTALL_USER=$(printf '%q' "$INSTALL_USER")
XRAY_WITH_GEODATA=$(printf '%q' "$WITH_GEODATA")
EOF_STATE
  chmod 600 "$STATE_FILE"
}

parse_args() {
  if [[ $# -gt 0 && "$1" != -* ]]; then
    ACTION="$1"
    shift
  fi

  case "$ACTION" in
    install|upgrade|service|status) ;;
    help) usage; exit 0 ;;
    *) die "Unknown action: $ACTION" ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || die "--version requires a value"
        TARGET_VERSION="$2"
        shift 2
        ;;
      --config-dir)
        [[ $# -ge 2 ]] || die "--config-dir requires a directory"
        CONFIG_DIR="$2"
        shift 2
        ;;
      --user)
        [[ $# -ge 2 ]] || die "--user requires a username"
        INSTALL_USER="$2"
        shift 2
        ;;
      --proxy)
        [[ $# -ge 2 ]] || die "--proxy requires a URL"
        PROXY="$2"
        shift 2
        ;;
      --without-geodata)
        WITH_GEODATA=0
        shift
        ;;
      --prerelease)
        PRERELEASE=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

validate_config_dir() {
  [[ -n "$CONFIG_DIR" ]] || die "Config directory cannot be empty."
  [[ "$CONFIG_DIR" = /* ]] || die "--config-dir must be an absolute path."
  [[ "$CONFIG_DIR" != *$'\n'* ]] || die "Config directory contains an invalid newline."
}

check_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl was not found; this script requires systemd."

  if [[ ! -d /run/systemd/system ]]; then
    warn "/run/systemd/system is not present. If this is a container/LXC, make sure systemd is PID 1."
  fi
}

install_dependencies() {
  local missing=0 cmd
  for cmd in curl unzip sha256sum install awk sed grep sort; do
    command -v "$cmd" >/dev/null 2>&1 || missing=1
  done
  [[ "$missing" -eq 0 ]] && return 0

  log "Installing required packages..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl unzip ca-certificates coreutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl unzip ca-certificates coreutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl unzip ca-certificates coreutils
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl unzip ca-certificates coreutils
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl unzip ca-certificates coreutils
  else
    die "Missing dependencies and no supported package manager was found. Install curl, unzip and coreutils manually."
  fi
}

curlx() {
  local args=(
    -L
    --fail
    --show-error
    --silent
    --retry 5
    --retry-delay 2
    --connect-timeout 15
  )
  [[ -n "$PROXY" ]] && args+=(--proxy "$PROXY")
  command curl "${args[@]}" "$@"
}

detect_arch() {
  case "$(uname -m)" in
    i386|i686)          printf '32' ;;
    amd64|x86_64)       printf '64' ;;
    armv5tel)           printf 'arm32-v5' ;;
    armv6l)             printf 'arm32-v6' ;;
    armv7|armv7l)       printf 'arm32-v7a' ;;
    armv8|aarch64)      printf 'arm64-v8a' ;;
    mips)               printf 'mips32' ;;
    mipsle)             printf 'mips32le' ;;
    mips64)             if lscpu 2>/dev/null | grep -qi 'Little Endian'; then printf 'mips64le'; else printf 'mips64'; fi ;;
    mips64le)           printf 'mips64le' ;;
    ppc64)              printf 'ppc64' ;;
    ppc64le)            printf 'ppc64le' ;;
    riscv64)            printf 'riscv64' ;;
    s390x)              printf 's390x' ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

current_version() {
  if [[ -x "$XRAY_BIN" ]]; then
    "$XRAY_BIN" -version 2>/dev/null | awk 'NR==1 {print "v" $2}' | sed 's/^vv/v/'
  fi
}

normalize_version() {
  local v="$1"
  if [[ "$v" == "latest" ]]; then
    printf 'latest'
  else
    printf 'v%s' "${v#v}"
  fi
}

version_cmp() {
  # Print -1/0/1 comparing two vX.Y.Z versions numerically.
  local a="${1#v}" b="${2#v}"
  local oldIFS="$IFS"
  IFS=.
  local -a A=($a) B=($b)
  IFS="$oldIFS"
  local i
  for i in 0 1 2; do
    local x="${A[i]:-0}" y="${B[i]:-0}"
    if ((10#${x:-0} < 10#${y:-0})); then printf -- '-1'; return 0; fi
    if ((10#${x:-0} > 10#${y:-0})); then printf '1'; return 0; fi
  done
  printf '0'
}

resolve_newest_release() {
  # Newest release including pre-releases. Xray-core has marked every
  # release since v26.4.25 as pre-release, so GitHub's /releases/latest
  # (which excludes them) can lag months behind.
  local json version

  if json="$(curlx -H 'Accept: application/vnd.github+json' \
      'https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1' 2>/dev/null)"; then
    version="$(printf '%s\n' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [[ -n "$version" ]]; then
      printf 'v%s' "${version#v}"
      return 0
    fi
  fi

  # Fallback: releases.atom is not rate-limited; newest entry comes first.
  local atom
  if atom="$(curlx 'https://github.com/XTLS/Xray-core/releases.atom' 2>/dev/null)"; then
    version="$(printf '%s\n' "$atom" | sed -n 's/.*releases\/tag\/\([^"<]*\).*/\1/p' | head -n1)"
    if [[ -n "$version" ]]; then
      printf 'v%s' "${version#v}"
      return 0
    fi
  fi

  die "Unable to resolve the newest Xray release."
}

resolve_latest_version() {
  local json version effective

  if [[ "$PRERELEASE" -eq 1 ]]; then
    resolve_newest_release
    return 0
  fi

  # First try GitHub API.
  if json="$(curlx -H 'Accept: application/vnd.github+json' \
      https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null)"; then
    version="$(printf '%s\n' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [[ -n "$version" ]]; then
      printf 'v%s' "${version#v}"
      return 0
    fi
  fi

  # Fallback avoids GitHub API rate-limit problems.
  effective="$(curlx -o /dev/null -w '%{url_effective}' https://github.com/XTLS/Xray-core/releases/latest)" || true
  version="${effective##*/}"
  [[ "$version" == v* ]] || die "Unable to resolve the latest Xray version."
  printf 'v%s' "${version#v}"
}

resolve_target_version() {
  local normalized
  normalized="$(normalize_version "$TARGET_VERSION")"
  if [[ "$normalized" == "latest" ]]; then
    resolve_latest_version
  else
    printf '%s' "$normalized"
  fi
}

prepare_user() {
  if id "$INSTALL_USER" >/dev/null 2>&1; then
    return 0
  fi

  [[ "$INSTALL_USER" != "root" ]] || return 0
  command -v useradd >/dev/null 2>&1 || die "User '$INSTALL_USER' does not exist and useradd is unavailable."

  local nologin_shell="/usr/sbin/nologin"
  [[ -x "$nologin_shell" ]] || nologin_shell="/sbin/nologin"
  [[ -x "$nologin_shell" ]] || nologin_shell="/bin/false"

  log "Creating system user: $INSTALL_USER"
  useradd --system --no-create-home --shell "$nologin_shell" "$INSTALL_USER"
}

prepare_directories() {
  local user_group
  user_group="$(id -gn "$INSTALL_USER")"

  if [[ ! -d "$CONFIG_DIR" ]]; then
    install -d -m 0750 -o root -g "$user_group" "$CONFIG_DIR"
  else
    # The directory may predate this install (e.g. created by the config
    # generator). Enforce ownership/mode so the service user can traverse it.
    chown root:"$user_group" "$CONFIG_DIR"
    chmod 0750 "$CONFIG_DIR"
  fi

  # A new confdir must contain at least one JSON file. Never overwrite user configs.
  if ! find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null | grep -q .; then
    log "No JSON config found; creating $CONFIG_DIR/00-base.json"
    printf '{}\n' >"$CONFIG_DIR/00-base.json"
  fi

  # ExecStartPre and the service run as $INSTALL_USER, so every JSON file in
  # the confdir must be group-readable. Existing files keep their owner.
  local json_file
  while IFS= read -r -d '' json_file; do
    if ! chgrp "$user_group" "$json_file" 2>/dev/null || ! chmod g+r "$json_file" 2>/dev/null; then
      warn "Could not make '$json_file' group-readable for user '$INSTALL_USER'."
    fi
  done < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.json' -print0)

  install -d -m 0750 -o "$INSTALL_USER" -g "$user_group" "$LOG_DIR"
  touch "$LOG_DIR/access.log" "$LOG_DIR/error.log"
  chown "$INSTALL_USER":"$user_group" "$LOG_DIR/access.log" "$LOG_DIR/error.log"
  chmod 0640 "$LOG_DIR/access.log" "$LOG_DIR/error.log"

  install -d -m 0755 "$ASSET_DIR"
}

download_release() {
  local arch="$1" version="$2"
  local base_url="https://github.com/XTLS/Xray-core/releases/download/${version}"
  local zip_name="Xray-linux-${arch}.zip"
  local zip_file="$TMP_DIR/$zip_name"
  local dgst_file="$zip_file.dgst"
  local expected actual

  log "Downloading Xray $version ($arch)..."
  curlx -o "$zip_file" "$base_url/$zip_name"
  curlx -o "$dgst_file" "$base_url/$zip_name.dgst"

  expected="$(awk -F '= ' '/256=/ {print $2; exit}' "$dgst_file" | tr -d '[:space:]')"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "Invalid SHA256 digest file for $version."

  actual="$(sha256sum "$zip_file" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "SHA256 verification failed."
  log "SHA256 verified."

  unzip -q "$zip_file" -d "$TMP_DIR/release"
  [[ -x "$TMP_DIR/release/xray" ]] || die "Downloaded archive does not contain the xray binary."
}

backup_current_installation() {
  if [[ -x "$XRAY_BIN" ]]; then
    HAD_OLD_BINARY=1
    BINARY_BACKUP="$TMP_DIR/xray.old"
    cp -a "$XRAY_BIN" "$BINARY_BACKUP"
  fi

  if [[ -f "$SERVICE_FILE" ]]; then
    HAD_OLD_SERVICE=1
    SERVICE_BACKUP="$TMP_DIR/xray.service.old"
    cp -a "$SERVICE_FILE" "$SERVICE_BACKUP"
  fi
}

install_release_files() {
  local release_dir="$TMP_DIR/release"

  install -m 0755 "$release_dir/xray" "$XRAY_BIN.new"
  mv -f "$XRAY_BIN.new" "$XRAY_BIN"

  if [[ "$WITH_GEODATA" -eq 1 ]]; then
    [[ -f "$release_dir/geoip.dat" ]] && install -m 0644 "$release_dir/geoip.dat" "$ASSET_DIR/geoip.dat"
    [[ -f "$release_dir/geosite.dat" ]] && install -m 0644 "$release_dir/geosite.dat" "$ASSET_DIR/geosite.dat"
  fi
}

write_service() {
  local user_group
  user_group="$(id -gn "$INSTALL_USER")"

  cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$INSTALL_USER
Group=$user_group
Environment=XRAY_LOCATION_ASSET=$ASSET_DIR
ExecStartPre=$XRAY_BIN run -test -confdir "$CONFIG_DIR"
ExecStart=$XRAY_BIN run -confdir "$CONFIG_DIR"
Restart=on-failure
RestartSec=3s
RestartPreventExitStatus=23
TimeoutStopSec=30s
KillSignal=SIGTERM
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755
UMask=0027
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
}

test_config_as_root() {
  log "Testing multi-file config: $CONFIG_DIR"
  if ! "$XRAY_BIN" run -test -confdir "$CONFIG_DIR"; then
    return 1
  fi
}

restore_previous_installation() {
  warn "Restoring previous installation..."

  if [[ "$HAD_OLD_BINARY" -eq 1 && -f "$BINARY_BACKUP" ]]; then
    install -m 0755 "$BINARY_BACKUP" "$XRAY_BIN"
  elif [[ "$HAD_OLD_BINARY" -eq 0 ]]; then
    rm -f "$XRAY_BIN"
  fi

  if [[ "$HAD_OLD_SERVICE" -eq 1 && -f "$SERVICE_BACKUP" ]]; then
    cp -a "$SERVICE_BACKUP" "$SERVICE_FILE"
  elif [[ "$HAD_OLD_SERVICE" -eq 0 ]]; then
    rm -f "$SERVICE_FILE"
  fi

  systemctl daemon-reload || true

  if [[ "$HAD_OLD_BINARY" -eq 1 && "$HAD_OLD_SERVICE" -eq 1 ]]; then
    systemctl restart "$SERVICE_NAME" || true
  fi
}

start_or_restart_service() {
  systemctl enable "$SERVICE_NAME" >/dev/null

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Restarting $SERVICE_NAME..."
    systemctl restart "$SERVICE_NAME"
  else
    log "Starting $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"
  fi

  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    return 1
  fi
}

show_status() {
  printf 'Binary:      %s\n' "$XRAY_BIN"
  printf 'Version:     %s\n' "$(current_version || true)"
  printf 'Config dir:  %s\n' "$CONFIG_DIR"
  printf 'Service:     %s\n' "$SERVICE_NAME"
  printf '\n'
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

main_install_or_upgrade() {
  local arch
  arch="$(detect_arch)"
  OLD_VERSION="$(current_version || true)"
  NEW_VERSION="$(resolve_target_version)"

  log "Current version: ${OLD_VERSION:-not installed}"
  log "Target version:  $NEW_VERSION"
  log "Config directory: $CONFIG_DIR"

  prepare_user
  prepare_directories
  backup_current_installation

  local need_binary=1
  if [[ -n "$OLD_VERSION" && "$OLD_VERSION" == "$NEW_VERSION" && "$FORCE" -eq 0 ]]; then
    need_binary=0
    log "Target version is already installed; keeping the current binary."
  elif [[ "$FORCE" -eq 0 && -n "$OLD_VERSION" \
      && "$(normalize_version "$TARGET_VERSION")" == "latest" && "$PRERELEASE" -eq 0 ]] \
      && [[ "$(version_cmp "$NEW_VERSION" "$OLD_VERSION")" == "-1" ]]; then
    # Installed a prerelease earlier; a plain "upgrade" must not silently
    # downgrade to the older newest-stable release.
    need_binary=0
    warn "Newest stable release ($NEW_VERSION) is older than the installed $OLD_VERSION; keeping the current binary."
    warn "Use --prerelease to update to the newest release, --version <VERSION> to pin one, or --force to downgrade."
  fi

  if [[ "$need_binary" -eq 1 ]]; then
    download_release "$arch" "$NEW_VERSION"
    install_release_files
  fi

  # Always refresh the managed service so --config-dir / --user changes take effect.
  write_service

  if ! test_config_as_root; then
    restore_previous_installation
    die "Xray configuration test failed; previous binary/service restored."
  fi

  if ! start_or_restart_service; then
    restore_previous_installation
    die "Xray failed to start; previous binary/service restored. Check: journalctl -u xray -n 100 --no-pager"
  fi

  save_state

  log "Xray is running successfully."
  log "Installed version: $(current_version)"
  log "Multi-config dir:  $CONFIG_DIR"
  log "Service:           $SERVICE_NAME"
}

main_service() {
  [[ -x "$XRAY_BIN" ]] || die "Xray is not installed at $XRAY_BIN"
  prepare_user
  prepare_directories
  backup_current_installation
  write_service

  if ! test_config_as_root; then
    restore_previous_installation
    die "Xray configuration test failed; service restored."
  fi

  if ! start_or_restart_service; then
    restore_previous_installation
    die "Xray failed to start; service restored."
  fi

  save_state
  log "systemd service updated successfully."
}

main() {
  require_root
  load_state
  parse_args "$@"
  validate_config_dir
  check_systemd

  case "$ACTION" in
    status)
      show_status
      ;;
    service)
      main_service
      ;;
    install|upgrade)
      install_dependencies
      TMP_DIR="$(mktemp -d)"
      main_install_or_upgrade
      ;;
  esac
}

main "$@"
