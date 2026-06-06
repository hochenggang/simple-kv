#!/usr/bin/env sh
# install.sh — install simple-kv as a system service.
# Supports Debian / Ubuntu / CentOS / RHEL / Arch (systemd) and Alpine (OpenRC).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hochenggang/simple-kv/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- v0.1.0
#
# Environment variables consumed by the service (read from /etc/simple-kv/simple-kv.env):
#   KV_PORT        listen port (default 8080)
#   KV_AUTH_TOKEN  optional bearer token

set -eu

GITHUB_REPO="hochenggang/simple-kv"
BIN_NAME="simple-kv"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/${BIN_NAME}"
CONFIG_FILE="${CONFIG_DIR}/${BIN_NAME}.env"
SERVICE_NAME="${BIN_NAME}"
TMP_DIR="$(mktemp -d)"

# ---- helpers ---------------------------------------------------------------

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARN: %s\n' "$*" >&2; }
err()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

require_root() {
    [ "$(id -u)" -eq 0 ] || err "must be run as root (try: sudo sh install.sh)"
}

# ---- OS / arch detection ---------------------------------------------------

detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID:-linux}"
    else
        echo "linux"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *) err "unsupported architecture: $(uname -m)" ;;
    esac
}

detect_init() {
    if [ -f /sbin/openrc-run ] || [ -f /usr/sbin/openrc-run ] || command -v openrc-run >/dev/null 2>&1; then
        echo "openrc"
    elif [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1; then
        echo "systemd"
    else
        err "no supported init system found (need systemd or OpenRC)"
    fi
}

# ---- download --------------------------------------------------------------

resolve_version() {
    if [ "${1:-}" ]; then
        VERSION="$1"
    else
        log "resolving latest release from GitHub..."
        VERSION=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
            | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        [ -n "${VERSION}" ] || err "could not determine latest release"
    fi
    log "version: ${VERSION}"
}

# Download a release asset with a 30s timeout. If the direct GitHub link is
# unreachable / too slow, transparently fall back to the ghproxy.net mirror.
#   $1 = relative or absolute URL (full https://github.com/... recommended)
#   $2 = output path
fetch_asset() {
    local url="$1" out="$2"
    local attempt=0
    local urls="
${url}
https://ghproxy.net/${url}
"

    # We can't use `set -e` short-circuiting cleanly with retries, so loop.
    while [ "${attempt}" -lt 2 ]; do
        attempt=$((attempt + 1))
        local current
        current=$(printf '%s' "${urls}" | sed -n "${attempt}p")
        log "downloading (attempt ${attempt}/2, timeout 30s) ${current}"
        if curl -fsSL --connect-timeout 10 --max-time 30 \
                -o "${out}" "${current}"; then
            return 0
        fi
        warn "download failed via ${current}"
        if [ "${attempt}" -lt 2 ]; then
            log "retrying via ghproxy.net mirror"
        fi
    done

    return 1
}

download_and_install() {
    local os="$1" arch="$2"
    # current CI only publishes linux/amd64; keep the matrix so future archs work.
    local target_os="linux"
    local target_arch="${arch}"
    local asset="${BIN_NAME}_${VERSION}_${target_os}_${target_arch}.tar.gz"
    local url="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/${asset}"

    fetch_asset "${url}" "${TMP_DIR}/${asset}" \
        || err "download failed — tried direct GitHub URL and ghproxy.net mirror"

    log "verifying checksum (if checksums.txt is published)"
    if fetch_asset \
        "https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/checksums.txt" \
        "${TMP_DIR}/checksums.txt" 2>/dev/null; then
        ( cd "${TMP_DIR}" && sha256sum -c --ignore-missing checksums.txt ) \
            || err "checksum verification failed"
    else
        warn "checksums.txt not available — skipping verification"
    fi

    log "extracting"
    tar -xzf "${TMP_DIR}/${asset}" -C "${TMP_DIR}"

    if [ ! -f "${TMP_DIR}/${BIN_NAME}_${VERSION}_${target_os}_${target_arch}" ]; then
        err "expected binary not found in archive"
    fi

    install -m 0755 "${TMP_DIR}/${BIN_NAME}_${VERSION}_${target_os}_${target_arch}" \
        "${INSTALL_DIR}/${BIN_NAME}"
    log "installed binary to ${INSTALL_DIR}/${BIN_NAME}"
}

# ---- config ----------------------------------------------------------------

DEFAULT_PORT=18100

# Prompt the user for the listen port. Falls back to the default when stdin is
# not a TTY (e.g. curl ... | sh) or when the user just hits enter.
prompt_port() {
    local current="${1:-}"
    local default="${2:-${DEFAULT_PORT}}"
    local prompt_default="${default}"
    local reply=""

    if [ -n "${current}" ]; then
        prompt_default="${current}"
    fi

    if [ -t 0 ]; then
        printf 'Listen port [%s]: ' "${prompt_default}" >&2
        # Read one line; tolerate missing read builtin on some shells.
        if read -r reply </dev/tty 2>/dev/null; then
            :
        else
            reply=""
        fi
    fi

    if [ -z "${reply}" ]; then
        reply="${prompt_default}"
    fi

    # Validate: integer 1-65535. Fall back to default on garbage.
    case "${reply}" in
        ''|*[!0-9]*) reply="${prompt_default}" ;;
    esac
    if [ "${reply}" -lt 1 ] || [ "${reply}" -gt 65535 ]; then
        warn "port out of range, using default ${default}"
        reply="${default}"
    fi

    printf '%s' "${reply}"
}

ensure_config() {
    mkdir -p "${CONFIG_DIR}"

    local existing_port=""
    if [ -f "${CONFIG_FILE}" ]; then
        existing_port=$(awk -F= '/^[[:space:]]*KV_PORT[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "${CONFIG_FILE}" 2>/dev/null || true)
        log "keeping existing ${CONFIG_FILE}"
    else
        local port
        port=$(prompt_port)
        cat > "${CONFIG_FILE}" <<EOF
# simple-kv service environment
KV_PORT=${port}
# KV_AUTH_TOKEN=change-me
EOF
        chmod 0640 "${CONFIG_FILE}"
        log "created ${CONFIG_FILE} (KV_PORT=${port})"
    fi
}

# ---- systemd ---------------------------------------------------------------

install_systemd() {
    local unit="/etc/systemd/system/${SERVICE_NAME}.service"
    log "writing systemd unit: ${unit}"

    cat > "${unit}" <<EOF
[Unit]
Description=simple-kv HTTP KV store
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${CONFIG_FILE}
ExecStart=${INSTALL_DIR}/${BIN_NAME}
Restart=on-failure
RestartSec=3
User=nobody
Group=nogroup
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if id nobody >/dev/null 2>&1 && getent group nogroup >/dev/null 2>&1; then
        : # default user/group are fine
    fi

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service" >/dev/null

    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        log "restarting existing service"
        systemctl restart "${SERVICE_NAME}.service"
    else
        log "starting service"
        systemctl start "${SERVICE_NAME}.service"
    fi

    sleep 1
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        log "service is active (systemctl status ${SERVICE_NAME}.service)"
    else
        warn "service did not become active — check: journalctl -u ${SERVICE_NAME}.service -n 50"
    fi
}

# ---- OpenRC ----------------------------------------------------------------

install_openrc() {
    local init="/etc/init.d/${SERVICE_NAME}"
    log "writing OpenRC init script: ${init}"

    cat > "${init}" <<EOF
#!/sbin/openrc-run

name="\${RC_SVCNAME}"
description="simple-kv HTTP KV store"
command="${INSTALL_DIR}/${BIN_NAME}"
command_args=""
command_user="nobody:nobody"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

start_pre() {
    if [ -f "${CONFIG_FILE}" ]; then
        set -a
        # shellcheck disable=SC1090
        . "${CONFIG_FILE}"
        set +a
    fi
    if [ -z "\${KV_PORT}" ]; then
        KV_PORT=8080
    fi
    export KV_PORT KV_AUTH_TOKEN
}

depend() {
    need net
    after firewall
}
EOF
    chmod 0755 "${init}"

    if rc-service --exists "${SERVICE_NAME}" 2>/dev/null; then
        rc-service "${SERVICE_NAME}" stop >/dev/null 2>&1 || true
    fi

    rc-update add "${SERVICE_NAME}" default >/dev/null

    if ! rc-service "${SERVICE_NAME}" start; then
        warn "OpenRC start returned non-zero — check: rc-service ${SERVICE_NAME} status"
    else
        log "service started (rc-service ${SERVICE_NAME} status)"
    fi
}

# ---- main ------------------------------------------------------------------

main() {
    require_root

    local os init
    os=$(detect_os)
    local arch
    arch=$(detect_arch)
    init=$(detect_init)

    log "detected: os=${os} arch=${arch} init=${init}"

    resolve_version "${1:-}"
    ensure_config
    download_and_install "${os}" "${arch}"

    case "${init}" in
        systemd) install_systemd ;;
        openrc)  install_openrc ;;
        *) err "unsupported init: ${init}" ;;
    esac

    log "done. Edit ${CONFIG_FILE} and restart the service to change settings."
}

main "$@"
