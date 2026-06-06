#!/usr/bin/env sh
# install.sh — install simple-kv as a system service.
# Supports Debian / Ubuntu / CentOS / RHEL / Arch (systemd) and Alpine (OpenRC).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hochenggang/simple-kv/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- v0.1.0
#   sudo sh install.sh -z ./simple-kv_v0.1.0_linux_amd64.tar.gz   # offline install
#   sudo sh install.sh -d                                          # upgrade to latest release
#
# Environment variables consumed by the service (read from /etc/simple-kv/simple-kv.env):
#   KV_PORT        listen port (default 8080)
#   KV_DATA_DIR    sqlite database directory (default ./data)
#   KV_AUTH_TOKEN  optional bearer token

set -eu

GITHUB_REPO="hochenggang/simple-kv"
BIN_NAME="simple-kv"
SVC_USER="${BIN_NAME}"            # unprivileged system user
SVC_GROUP="${BIN_NAME}"           # group with the same name
DATA_DIR="/var/lib/${BIN_NAME}"   # WorkingDirectory + base for KV_DATA_DIR
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/${BIN_NAME}"
CONFIG_FILE="${CONFIG_DIR}/${BIN_NAME}.env"
SERVICE_NAME="${BIN_NAME}"
TMP_DIR="$(mktemp -d)"

# Populated by parse_args().
LOCAL_TARBALL=""
UPGRADE_ONLY=0

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
    if [ -n "${LOCAL_TARBALL}" ]; then
        # Extract version from the filename: simple-kv_<ver>_<os>_<arch>.tar.gz
        VERSION=$(basename "${LOCAL_TARBALL}" \
            | sed -n 's/^simple-kv_\(v[^_]*\)_.*/\1/p')
        [ -n "${VERSION}" ] || err "could not extract version from LOCAL_TARBALL='${LOCAL_TARBALL}' (expected pattern: simple-kv_<ver>_<os>_<arch>.tar.gz)"
        log "version (from local tarball): ${VERSION}"
        return 0
    fi

    # -d always pulls the latest release from GitHub, ignoring any version arg.
    if [ "${UPGRADE_ONLY}" = "1" ] || [ -z "${1:-}" ]; then
        log "resolving latest release from GitHub..."
        VERSION=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
            | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        [ -n "${VERSION}" ] || err "could not determine latest release"
    else
        VERSION="$1"
    fi
    log "version: ${VERSION}"
}

# Download a release asset with a 30s timeout. If the direct GitHub link is
# unreachable / too slow, transparently fall back to the ghproxy.net mirror.
#   $1 = full https://github.com/... URL
#   $2 = output path
fetch_asset() {
    local url="$1" out="$2"
    local mirror="https://ghproxy.net/${url}"
    local attempt=0
    local max_attempts=2
    local current=""
    local label=""

    while [ "${attempt}" -lt "${max_attempts}" ]; do
        attempt=$((attempt + 1))
        if [ "${attempt}" -eq 1 ]; then
            current="${url}"
            label="direct GitHub URL"
        else
            current="${mirror}"
            label="ghproxy.net mirror"
        fi

        log "downloading (attempt ${attempt}/${max_attempts}, timeout 30s) via ${label}"
        if curl -fsSL --connect-timeout 10 --max-time 30 \
                -o "${out}" "${current}"; then
            return 0
        fi
        warn "download failed via ${label}: ${current}"
        if [ "${attempt}" -lt "${max_attempts}" ]; then
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

    if [ -n "${LOCAL_TARBALL}" ]; then
        log "offline install mode: using local tarball ${LOCAL_TARBALL}"
        [ -f "${LOCAL_TARBALL}" ] || err "local tarball not found: ${LOCAL_TARBALL}"
        cp -f "${LOCAL_TARBALL}" "${TMP_DIR}/${asset}"
    else
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

# ---- service user / dirs ---------------------------------------------------

# Create a dedicated system user with no shell, no home, no password, and a
# matching primary group. Idempotent: if the user already exists, leave it.
# Also prepares ${DATA_DIR} and chowns ${CONFIG_DIR} to that user.
create_service_user_and_dirs() {
    local nologin_shell=""
    if [ -f /etc/alpine-release ]; then
        # BusyBox adduser flags: -S system, -D no password, -H no home, -s shell
        # NB: -g is GECOS, -G is primary group. They are different!
        nologin_shell="/sbin/nologin"

        # Make sure the group exists first; BusyBox adduser -G requires an
        # existing group. addgroup -S creates a system group.
        if ! getent group "${SVC_GROUP}" >/dev/null 2>&1; then
            log "creating system group ${SVC_GROUP} (Alpine)"
            addgroup -S "${SVC_GROUP}" \
                || err "failed to create system group ${SVC_GROUP}"
        else
            log "system group ${SVC_GROUP} already exists"
        fi

        if ! id "${SVC_USER}" >/dev/null 2>&1; then
            log "creating system user ${SVC_USER} (Alpine)"
            adduser -S -D -H \
                -s "${nologin_shell}" \
                -G "${SVC_GROUP}" \
                -g "simple-kv service account" \
                "${SVC_USER}" \
                || err "failed to create system user ${SVC_USER}"
        else
            log "system user ${SVC_USER} already exists"
        fi
    else
        # shadow-utils useradd. --system picks a low UID/GID, --no-create-home
        # avoids /home, --shell prevents login. --user-group creates a same-named
        # primary group if it doesn't already exist.
        if command -v nologin >/dev/null 2>&1; then
            nologin_shell="$(command -v nologin)"
        elif [ -x /usr/sbin/nologin ]; then
            nologin_shell="/usr/sbin/nologin"
        elif [ -x /bin/false ]; then
            nologin_shell="/bin/false"
        else
            nologin_shell="/usr/sbin/nologin"
        fi

        if ! id "${SVC_USER}" >/dev/null 2>&1; then
            log "creating system user ${SVC_USER}"
            useradd --system \
                --no-create-home \
                --home-dir "${DATA_DIR}" \
                --shell "${nologin_shell}" \
                --user-group \
                --comment "simple-kv service account" \
                "${SVC_USER}" \
                || err "failed to create system user ${SVC_USER}"
        else
            log "system user ${SVC_USER} already exists"
            # Make sure the existing account has no valid login shell either.
            current_shell=$(getent passwd "${SVC_USER}" | cut -d: -f7)
            case "${current_shell}" in
                */nologin|/bin/false|/usr/sbin/nologin|/sbin/nologin) : ;;
                *) warn "existing ${SVC_USER} has login shell '${current_shell}'; not changing it" ;;
            esac
        fi
    fi

    install -d -m 0750 -o "${SVC_USER}" -g "${SVC_GROUP}" "${DATA_DIR}"
    log "data dir ${DATA_DIR} owned by ${SVC_USER}:${SVC_GROUP}"

    # CONFIG_DIR is what users edit; grant the service user ownership so its
    # files (env file, future TLS material, ...) are readable in the OpenRC
    # flow that sources the env file as the service user.
    if [ -d "${CONFIG_DIR}" ]; then
        chown -R "${SVC_USER}:${SVC_GROUP}" "${CONFIG_DIR}"
        log "chowned ${CONFIG_DIR} to ${SVC_USER}:${SVC_GROUP}"
    fi
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
KV_DATA_DIR=${DATA_DIR}/data
# KV_AUTH_TOKEN=change-me
EOF
        chmod 0640 "${CONFIG_FILE}"
        log "created ${CONFIG_FILE} (KV_PORT=${port}, KV_DATA_DIR=${DATA_DIR}/data)"
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
WorkingDirectory=${DATA_DIR}
ExecStart=${INSTALL_DIR}/${BIN_NAME}
Restart=on-failure
RestartSec=3
User=${SVC_USER}
Group=${SVC_GROUP}
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

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
command_user="${SVC_USER}:${SVC_GROUP}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
directory="${DATA_DIR}"

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
    if [ -z "\${KV_DATA_DIR}" ]; then
        KV_DATA_DIR="${DATA_DIR}/data"
    fi
    export KV_PORT KV_AUTH_TOKEN KV_DATA_DIR
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

# ---- arg parsing ------------------------------------------------------------

# Usage: parse_args "$@"
# Sets globals: LOCAL_TARBALL, REQUESTED_VERSION
# Leaves the version positional in $1 for backwards compatibility.
print_usage() {
    cat >&2 <<EOF
Usage: install.sh [options] [version]

Options:
  -z <path>   Install from a local tarball (e.g. ./simple-kv_v0.1.0_linux_amd64.tar.gz).
              Skips all network requests.
  -d          Upgrade mode: pull the latest release from GitHub, replace the
              installed binary, and restart the service. Skips user creation
              and config prompts; existing /etc/simple-kv and /var/lib/simple-kv
              are left untouched.
  -h          Show this help.

Positional:
  version     Optional release tag (e.g. v0.1.0). Ignored when -z is used.
              In -d mode the version is always the latest GitHub release.

Examples:
  curl -fsSL https://.../install.sh | sudo sh
  curl -fsSL https://.../install.sh | sudo sh -s -- v0.1.0
  sudo sh install.sh -d
  sudo sh install.sh -z ./simple-kv_v0.1.0_linux_amd64.tar.gz
EOF
}

parse_args() {
    REQUESTED_VERSION=""
    while getopts ":z:dh" opt; do
        case "${opt}" in
            z) LOCAL_TARBALL="${OPTARG}" ;;
            d) UPGRADE_ONLY=1 ;;
            h) print_usage; exit 0 ;;
            :) err "option -${OPTARG} requires an argument" ;;
            \?) err "unknown option: -${OPTARG}" ;;
        esac
    done
    shift $((OPTIND - 1))
    if [ "${1:-}" ]; then
        REQUESTED_VERSION="$1"
    fi
    if [ "${UPGRADE_ONLY}" = "1" ] && [ -n "${LOCAL_TARBALL}" ]; then
        err "-d and -z are mutually exclusive"
    fi
}

# ---- main ------------------------------------------------------------------

main() {
    parse_args "$@"
    require_root

    local os init
    os=$(detect_os)
    local arch
    arch=$(detect_arch)
    init=$(detect_init)

    log "detected: os=${os} arch=${arch} init=${init}"
    if [ -n "${LOCAL_TARBALL}" ]; then
        log "mode: offline (local tarball)"
    fi
    if [ "${UPGRADE_ONLY}" = "1" ]; then
        log "mode: upgrade (replace binary with latest GitHub release)"
        # Make sure the service unit itself exists; user/dirs are assumed to
        # already be in place from a prior install.
        if [ ! -f "${INSTALL_DIR}/${BIN_NAME}" ]; then
            err "no existing install at ${INSTALL_DIR}/${BIN_NAME} — run without -d first"
        fi
    else
        create_service_user_and_dirs
    fi

    resolve_version "${REQUESTED_VERSION}"
    ensure_config
    download_and_install "${os}" "${arch}"

    case "${init}" in
        systemd) install_systemd ;;
        openrc)  install_openrc ;;
        *) err "unsupported init: ${init}" ;;
    esac

    if [ "${UPGRADE_ONLY}" = "1" ]; then
        # Force-restart the service in upgrade mode (in case it was stopped,
        # or to pick up the new binary). Both init scripts restart-on-active
        # only, so we trigger an explicit start/restart here.
        case "${init}" in
            systemd)
                if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
                    log "restarting service (upgrade)"
                    systemctl restart "${SERVICE_NAME}.service"
                else
                    log "starting service (upgrade)"
                    systemctl start "${SERVICE_NAME}.service"
                fi
                ;;
            openrc)
                if rc-service --exists "${SERVICE_NAME}" 2>/dev/null; then
                    log "restarting service (upgrade)"
                    rc-service "${SERVICE_NAME}" restart >/dev/null 2>&1 || \
                        rc-service "${SERVICE_NAME}" start
                fi
                ;;
        esac
    fi

    log "done. Edit ${CONFIG_FILE} and restart the service to change settings."
}

main "$@"
