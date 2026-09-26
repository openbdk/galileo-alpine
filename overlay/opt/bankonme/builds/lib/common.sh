#!/usr/bin/env bash
# builds/lib/common.sh — shared by builds/debian/descartes.build and
# builds/alpine/chomsky.build. Sourced, never executed.
#
# Provides: logging, root/arch checks, checksum-verified downloads,
# Foundry install, Bitcoin Core source build, bitcoin.conf with the
# read-only AION RPC user.

BUILDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "${BUILDS_DIR}/versions.env"

readonly LOG_DIR="/var/log/bankonme"
readonly CONF_DIR="/etc/bankonme"
readonly SRC_DIR="/usr/local/src/bankonme"
readonly BTC_DATADIR="${BTC_DATADIR:-/var/lib/bankon-bitcoin}"
readonly BTC_CONF="${CONF_DIR}/bitcoin.conf"
readonly AION_RPC_FILE="${CONF_DIR}/aion-bitcoin.rpc"
BITCOIN_PRUNE="${BITCOIN_PRUNE:-0}"   # MiB of blocks to keep; 0 = full node

readonly GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m'
readonly RED='\033[0;31m' BOLD='\033[1m' CYAN='\033[0;36m' NC='\033[0m'

BUILD_LOG="${LOG_DIR}/builds.log"

_ts()     { date '+%H:%M:%S'; }
_logf()   { echo "[$(_ts)] [${CODENAME}] $*" >> "${BUILD_LOG}" 2>/dev/null || true; }
log()     { echo -e "${BLUE}[${CODENAME}]${NC} $*"; _logf "$*"; }
success() { echo -e "${GREEN}[  OK  ]${NC} $*"; _logf "OK: $*"; }
warn()    { echo -e "${YELLOW}[ WARN ]${NC} $*"; _logf "WARN: $*"; }
fail()    { echo -e "${RED}[FAILED]${NC} $*"; _logf "FAIL: $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; _logf "── $* ──"; }

need_root() {
    [[ $EUID -eq 0 ]] || fail "run as root (sudo or doas)"
    mkdir -p "${LOG_DIR}" "${CONF_DIR}" "${SRC_DIR}"
    chmod 755 "${CONF_DIR}"
}

# Normalised arch: sets ARCH_GNU (x86_64|aarch64) and ARCH_GO (amd64|arm64).
detect_arch() {
    ARCH_GNU="$(uname -m)"
    case "${ARCH_GNU}" in
        x86_64)        ARCH_GO="amd64" ;;
        aarch64|arm64) ARCH_GNU="aarch64"; ARCH_GO="arm64" ;;
        *) fail "unsupported architecture: ${ARCH_GNU} (x86_64 and aarch64 only)" ;;
    esac
}

# fetch_verified URL DEST SHA256 — download once, refuse on hash mismatch.
fetch_verified() {
    local url="$1" dest="$2" want="$3" got
    [[ -n "${want}" ]] || fail "no pinned sha256 for ${url} — add it to builds/versions.env"
    if [[ -f "${dest}" ]] && echo "${want}  ${dest}" | sha256sum -c - >/dev/null 2>&1; then
        log "cached: $(basename "${dest}")"
        return 0
    fi
    log "fetch: ${url}"
    local progress="-sS"; [[ -t 2 ]] && progress="--progress-bar"
    curl -fL "${progress}" --proto '=https' --tlsv1.2 --retry 3 -o "${dest}.part" "${url}" \
        || fail "download failed: ${url}"
    got="$(sha256sum "${dest}.part" | awk '{print $1}')"
    if [[ "${got}" != "${want}" ]]; then
        rm -f "${dest}.part"
        fail "sha256 mismatch for $(basename "${dest}"): got ${got}, pinned ${want}"
    fi
    mv "${dest}.part" "${dest}"
    success "sha256 ok: $(basename "${dest}")"
}

# ─── Foundry ─────────────────────────────────────────────────────────
# install_foundry FLAVOR — FLAVOR is "alpine" (musl) or "linux" (glibc).
# Installs forge, cast, anvil, chisel into /usr/local/bin for all users.
install_foundry() {
    local flavor="$1" key sha tarball url tmp
    detect_arch
    key="FOUNDRY_SHA256_${flavor}_${ARCH_GO}"
    sha="${!key:-}"
    tarball="foundry_${FOUNDRY_VERSION}_${flavor}_${ARCH_GO}.tar.gz"
    url="https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}/${tarball}"

    step "Foundry ${FOUNDRY_VERSION} (${flavor}/${ARCH_GO})"
    fetch_verified "${url}" "${SRC_DIR}/${tarball}" "${sha}"
    tmp="$(mktemp -d)"
    tar -xzf "${SRC_DIR}/${tarball}" -C "${tmp}"
    local b
    for b in forge cast anvil chisel; do
        [[ -f "${tmp}/${b}" ]] && install -m 0755 "${tmp}/${b}" "/usr/local/bin/${b}"
    done
    rm -rf "${tmp}"
    forge --version | head -1 || fail "forge installed but does not run"
    success "Foundry installed to /usr/local/bin"
}

# ─── Bitcoin Core from source (CMake, v29+) ──────────────────────────
# Wallet (SQLite) and ZMQ on, GUI and IPC off. BITCOIN_GUI=1 builds bitcoin-qt.
bitcoin_build_source() {
    local tarball="bitcoin-${BITCOIN_VERSION}.tar.gz"
    local url="https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/${tarball}"
    local src="${SRC_DIR}/bitcoin-${BITCOIN_VERSION}"
    local gui="OFF"; [[ "${BITCOIN_GUI:-0}" == 1 ]] && gui="ON"

    step "Bitcoin Core ${BITCOIN_VERSION} — source build"
    fetch_verified "${url}" "${SRC_DIR}/${tarball}" "${BITCOIN_SRC_SHA256}"
    bitcoin_verify_gpg
    rm -rf "${src}"
    tar -xzf "${SRC_DIR}/${tarball}" -C "${SRC_DIR}"

    cmake -S "${src}" -B "${src}/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_GUI="${gui}" \
        -DENABLE_WALLET=ON \
        -DWITH_ZMQ=ON \
        -DENABLE_IPC=OFF \
        -DBUILD_TESTS=OFF -DBUILD_BENCH=OFF -DBUILD_FUZZ_BINARY=OFF \
        || fail "cmake configure failed"
    cmake --build "${src}/build" -j "$(nproc)" || fail "build failed"
    cmake --install "${src}/build" --strip || fail "install failed"
    bitcoind -version | head -1
    success "Bitcoin Core ${BITCOIN_VERSION} built from verified source"
}

# Optional GPG check of SHA256SUMS against the guix builder keys.
# BITCOIN_GPG_VERIFY=1 makes it mandatory; otherwise it is skipped with a note,
# since the tarball is already pinned by sha256 in versions.env.
bitcoin_verify_gpg() {
    [[ "${BITCOIN_GPG_VERIFY:-0}" == 1 ]] || { log "gpg check skipped (BITCOIN_GPG_VERIFY=1 to enable)"; return 0; }
    command -v gpg >/dev/null || fail "BITCOIN_GPG_VERIFY=1 needs gpg"
    local base="https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}"
    local d; d="$(mktemp -d)"
    curl -fsSL -o "${d}/SHA256SUMS" "${base}/SHA256SUMS"
    curl -fsSL -o "${d}/SHA256SUMS.asc" "${base}/SHA256SUMS.asc"
    grep -q "${BITCOIN_SRC_SHA256}  bitcoin-${BITCOIN_VERSION}.tar.gz" "${d}/SHA256SUMS" \
        || fail "pinned source hash not present in upstream SHA256SUMS"
    log "importing guix builder keys"
    local keys; keys="$(mktemp -d)"
    git clone -q --depth 1 https://github.com/bitcoin-core/guix.sigs "${keys}" \
        || fail "cannot fetch guix.sigs"
    GNUPGHOME="${d}/gnupg" gpg --batch --quiet --import "${keys}"/builder-keys/*.gpg 2>/dev/null || true
    local good
    good="$(GNUPGHOME="${d}/gnupg" gpg --batch --status-fd 1 --verify "${d}/SHA256SUMS.asc" "${d}/SHA256SUMS" 2>/dev/null | grep -c '^\[GNUPG:\] GOODSIG' || true)"
    rm -rf "${d}" "${keys}"
    [[ "${good}" -ge 3 ]] || fail "only ${good} good builder signatures on SHA256SUMS (want >= 3)"
    success "SHA256SUMS signed by ${good} guix builders"
}

# ─── bitcoin.conf + read-only AION RPC user ──────────────────────────
# AION's ML layer reads chain state through a dedicated rpcauth user that is
# whitelisted to read-only calls. It can never sign, send or touch a wallet.
readonly AION_RPC_WHITELIST="getblockchaininfo,getblockcount,getblockhash,getblockheader,getblockstats,getmempoolinfo,getnetworkinfo,estimatesmartfee,getchaintxstats,uptime"

bitcoin_configure() {
    local btc_user="$1"   # system user the daemon runs as
    step "bitcoin.conf (${BTC_CONF})"
    mkdir -p "${BTC_DATADIR}"
    chown "${btc_user}:${btc_user}" "${BTC_DATADIR}"
    chmod 750 "${BTC_DATADIR}"

    local pass salt hash
    if [[ -f "${AION_RPC_FILE}" ]]; then
        # shellcheck disable=SC1090
        pass="$(. "${AION_RPC_FILE}"; echo "${AION_BTC_RPC_PASS}")"
        log "reusing AION RPC credentials from ${AION_RPC_FILE}"
    else
        pass="$(openssl rand -hex 32)"
    fi
    salt="$(openssl rand -hex 16)"
    # Same construction as bitcoin/share/rpcauth/rpcauth.py
    hash="$(printf '%s' "${pass}" | openssl dgst -sha256 -hmac "${salt}" | awk '{print $NF}')"

    if [[ -f "${BTC_CONF}" ]] && ! grep -q '^# managed by bankonOS builds' "${BTC_CONF}"; then
        cp -a "${BTC_CONF}" "${BTC_CONF}.bak.$(date +%s)"
        warn "existing ${BTC_CONF} backed up"
    fi
    cat > "${BTC_CONF}" <<EOF
# managed by bankonOS builds (${CODENAME}) — edit freely, rerun keeps a backup
server=1
txindex=0
prune=${BITCOIN_PRUNE}
dbcache=1024
listen=1
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
# cookie readable by group ${btc_user}: the bankonbtcwaas extension attaches with it
rpccookieperms=group
zmqpubhashblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333

# AION ML layer — read-only
rpcauth=aion:${salt}\$${hash}
rpcwhitelist=aion:${AION_RPC_WHITELIST}
rpcwhitelistdefault=0
EOF
    chown "root:${btc_user}" "${BTC_CONF}"
    chmod 640 "${BTC_CONF}"

    umask 077
    cat > "${AION_RPC_FILE}" <<EOF
AION_BTC_RPC_URL=http://127.0.0.1:8332
AION_BTC_RPC_USER=aion
AION_BTC_RPC_PASS=${pass}
EOF
    chmod 600 "${AION_RPC_FILE}"
    success "bitcoin.conf written; AION read-only RPC creds in ${AION_RPC_FILE}"
}

verify_tools() {
    step "verify"
    local rc=0 t
    for t in bitcoind bitcoin-cli forge cast anvil; do
        if command -v "${t}" >/dev/null; then
            printf '  %-12s %s\n' "${t}" "$("${t}" --version 2>/dev/null | head -1)"
        else
            printf '  %-12s %s\n' "${t}" "MISSING"; rc=1
        fi
    done
    [[ -f "${BTC_CONF}" ]] && echo "  bitcoin.conf  ${BTC_CONF}" || { echo "  bitcoin.conf  MISSING"; rc=1; }
    return ${rc}
}
