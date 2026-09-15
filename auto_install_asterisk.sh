#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

DEFAULT_ASTERISK_VERSION='22.11.0'
DEFAULT_ASTERISK_SHA256='3bd5ee040509a3d3cd9b1ba9520c18e6ec0a7e7981ca68c457dcd36ba3c54d94'

ASTERISK_VERSION=$DEFAULT_ASTERISK_VERSION
ASTERISK_SHA256=$DEFAULT_ASTERISK_SHA256
SOURCE_ROOT='/usr/local/src/asterisk-deployment'
LOG_DIR='/var/log/asterisk-deployment'
BUILD_JOBS=''
INSTALL_SAMPLES=0
ENABLE_SERVICE=0
START_SERVICE=0
UPSTREAM_PREREQS=0
PRINT_PLAN=0
VERSION_EXPLICIT=0
SHA_EXPLICIT=0

usage() {
    cat <<'EOF'
Usage:
  auto_install_asterisk.sh [options]

Options:
  --version VERSION        Asterisk release to install.
  --sha256 SHA256          Expected SHA-256 for the release tarball.
  --jobs N                 Parallel make jobs. Default: detected CPU count.
  --source-root DIR        Build/download directory.
  --install-samples        Install upstream sample configs on a fresh config directory only.
  --upstream-prereqs       Run verified source's contrib/scripts/install_prereq install.
  --enable-service         Enable the generated systemd service.
  --start                  Enable and start Asterisk after installation.
  --print-plan             Print the resolved plan without changing the system.
  -h, --help               Show this help.

Defaults are pinned to Asterisk 22.11.0 LTS and its SHA-256 digest.
The script targets AlmaLinux 9 and must be run as root unless --help or --print-plan is used.
EOF
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

while (($# > 0)); do
    case $1 in
        --version)
            (($# >= 2)) || fatal '--version requires a value.'
            ASTERISK_VERSION=$2
            VERSION_EXPLICIT=1
            shift 2
            ;;
        --sha256)
            (($# >= 2)) || fatal '--sha256 requires a value.'
            ASTERISK_SHA256=${2,,}
            SHA_EXPLICIT=1
            shift 2
            ;;
        --jobs)
            (($# >= 2)) || fatal '--jobs requires a value.'
            BUILD_JOBS=$2
            shift 2
            ;;
        --source-root)
            (($# >= 2)) || fatal '--source-root requires a value.'
            SOURCE_ROOT=$2
            shift 2
            ;;
        --install-samples)
            INSTALL_SAMPLES=1
            shift
            ;;
        --upstream-prereqs)
            UPSTREAM_PREREQS=1
            shift
            ;;
        --enable-service)
            ENABLE_SERVICE=1
            shift
            ;;
        --start)
            START_SERVICE=1
            ENABLE_SERVICE=1
            shift
            ;;
        --print-plan)
            PRINT_PLAN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fatal "Unknown option: $1"
            ;;
    esac
done

[[ $ASTERISK_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal 'Asterisk version must use X.Y.Z format.'
[[ $ASTERISK_SHA256 =~ ^[0-9a-f]{64}$ ]] || fatal 'SHA-256 must be 64 lowercase hexadecimal characters.'

if ((VERSION_EXPLICIT == 1 && SHA_EXPLICIT == 0)) && [[ $ASTERISK_VERSION != $DEFAULT_ASTERISK_VERSION ]]; then
    fatal 'When overriding --version, provide the matching --sha256 explicitly.'
fi

if [[ -z $BUILD_JOBS ]]; then
    if command -v nproc >/dev/null 2>&1; then
        BUILD_JOBS=$(nproc)
    else
        BUILD_JOBS=1
    fi
fi
[[ $BUILD_JOBS =~ ^[1-9][0-9]*$ ]] || fatal '--jobs must be a positive integer.'

SOURCE_URL="https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-${ASTERISK_VERSION}.tar.gz"
TARBALL="${SOURCE_ROOT}/asterisk-${ASTERISK_VERSION}.tar.gz"
BUILD_DIR="${SOURCE_ROOT}/asterisk-${ASTERISK_VERSION}"

print_plan() {
    cat <<EOF
Asterisk deployment plan
  version:            ${ASTERISK_VERSION}
  sha256:             ${ASTERISK_SHA256}
  source URL:         ${SOURCE_URL}
  source root:        ${SOURCE_ROOT}
  build jobs:         ${BUILD_JOBS}
  install samples:    ${INSTALL_SAMPLES}
  upstream prereqs:   ${UPSTREAM_PREREQS}
  enable service:     ${ENABLE_SERVICE}
  start service:      ${START_SERVICE}
EOF
}

if ((PRINT_PLAN == 1)); then
    print_plan
    exit 0
fi

((EUID == 0)) || fatal 'Run this script as root.'
[[ -r /etc/os-release ]] || fatal '/etc/os-release is missing.'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == 'almalinux' ]] || fatal "Unsupported distribution: ${ID:-unknown}. This installer targets AlmaLinux 9."
[[ ${VERSION_ID%%.*} == '9' ]] || fatal "Unsupported AlmaLinux release: ${VERSION_ID:-unknown}. Expected major version 9."

install -d -m 0750 "$LOG_DIR"
LOG_FILE="${LOG_DIR}/install-$(date '+%Y%m%d-%H%M%S').log"
touch "$LOG_FILE"
chmod 0640 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Starting Asterisk ${ASTERISK_VERSION} source deployment."
print_plan

require_command dnf
require_command systemctl
require_command sha256sum

log 'Installing deterministic bootstrap/build dependencies.'
dnf install -y \
    ca-certificates \
    curl \
    tar \
    gzip \
    bzip2 \
    patch \
    make \
    gcc \
    gcc-c++ \
    pkgconf-pkg-config \
    libedit-devel \
    jansson-devel \
    libuuid-devel \
    sqlite-devel \
    libxml2-devel \
    openssl-devel \
    ncurses-devel

install -d -m 0755 "$SOURCE_ROOT"

log "Downloading ${SOURCE_URL}."
curl \
    --fail \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --output "${TARBALL}.tmp" \
    "$SOURCE_URL"

printf '%s  %s\n' "$ASTERISK_SHA256" "${TARBALL}.tmp" | sha256sum --check --status \
    || fatal 'Downloaded Asterisk archive failed SHA-256 verification.'
mv -f -- "${TARBALL}.tmp" "$TARBALL"
log 'Source archive SHA-256 verified.'

if [[ -e $BUILD_DIR ]]; then
    fatal "Build directory already exists: $BUILD_DIR. Remove or move it before rerunning."
fi

tar -xzf "$TARBALL" -C "$SOURCE_ROOT"
[[ -x "$BUILD_DIR/configure" ]] || fatal 'Extracted source tree is incomplete: configure is missing.'
cd "$BUILD_DIR"

if ((UPSTREAM_PREREQS == 1)); then
    [[ -x ./contrib/scripts/install_prereq ]] || fatal 'Upstream install_prereq script is missing.'
    log 'Running upstream prerequisite installer from the checksum-verified source tree.'
    ./contrib/scripts/install_prereq install
fi

log 'Configuring Asterisk with bundled pjproject.'
./configure --with-pjproject-bundled

log "Building Asterisk with ${BUILD_JOBS} parallel job(s)."
make -j"$BUILD_JOBS"

log 'Installing Asterisk binaries and modules.'
make install
make install-logrotate
ldconfig

ASTERISK_BIN=$(command -v asterisk || true)
[[ -n $ASTERISK_BIN && -x $ASTERISK_BIN ]] || fatal 'Asterisk binary was not found in PATH after make install.'
log "Installed binary: $ASTERISK_BIN"
"$ASTERISK_BIN" -V

if ! getent group asterisk >/dev/null 2>&1; then
    groupadd --system asterisk
fi
if ! id asterisk >/dev/null 2>&1; then
    useradd \
        --system \
        --gid asterisk \
        --home-dir /var/lib/asterisk \
        --shell /sbin/nologin \
        asterisk
fi

install -d -o asterisk -g asterisk -m 0750 \
    /var/lib/asterisk \
    /var/log/asterisk \
    /var/spool/asterisk
install -d -o asterisk -g asterisk -m 0750 /run/asterisk
install -d -o root -g asterisk -m 0750 /etc/asterisk

if ((INSTALL_SAMPLES == 1)); then
    if find /etc/asterisk -maxdepth 1 -type f -name '*.conf' -print -quit | grep -q .; then
        fatal '--install-samples refuses to overwrite an existing Asterisk configuration. Use a fresh /etc/asterisk directory.'
    fi

    log 'Installing upstream sample configuration files.'
    make samples
    find /etc/asterisk -maxdepth 1 -type f -name '*.conf' -exec chown root:asterisk {} +
    find /etc/asterisk -maxdepth 1 -type f -name '*.conf' -exec chmod 0640 {} +
fi

log 'Installing systemd service unit.'
cat > /etc/systemd/system/asterisk.service <<EOF
[Unit]
Description=Asterisk PBX
Documentation=https://docs.asterisk.org/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=asterisk
Group=asterisk
RuntimeDirectory=asterisk
RuntimeDirectoryMode=0750
ExecStart=${ASTERISK_BIN} -f -C /etc/asterisk/asterisk.conf
ExecReload=${ASTERISK_BIN} -rx 'core reload'
ExecStop=${ASTERISK_BIN} -rx 'core stop now'
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/asterisk.service
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/asterisk.service

if ((ENABLE_SERVICE == 1)); then
    systemctl enable asterisk.service
fi

if ((START_SERVICE == 1)); then
    [[ -s /etc/asterisk/asterisk.conf ]] \
        || fatal '--start requires /etc/asterisk/asterisk.conf. Supply your configuration or use --install-samples for a lab system.'

    systemctl restart asterisk.service
    systemctl is-active --quiet asterisk.service \
        || fatal 'Asterisk service did not become active.'
    "$ASTERISK_BIN" -rx 'core show version'
fi

log 'Deployment completed.'
log "Full log: $LOG_FILE"
if ((START_SERVICE == 0)); then
    log 'Asterisk was installed but not started. Review /etc/asterisk before enabling production service.'
fi
