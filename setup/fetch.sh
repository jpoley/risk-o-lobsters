#!/usr/bin/env bash
set -euo pipefail

# fetch.sh — Download binaries and clone repos for Claw platforms
#
# No root needed. No users touched. Just downloads.
#
# Usage:
#   ./fetch.sh                    # Fetch all 4
#   ./fetch.sh nanoclaw           # Fetch one
#   ./fetch.sh --status           # Show what's downloaded

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="${SCRIPT_DIR}/../.repos"
STATUS_ONLY=false

ALL_PLATFORMS=(nanoclaw zeroclaw openclaw ironclaw)

declare -A PLATFORM_DISPLAY=(
    [nanoclaw]="NanoClaw"  [zeroclaw]="ZeroClaw"
    [openclaw]="OpenClaw"  [ironclaw]="IronClaw"
)

# ── Supply-chain verification for ZeroClaw ───────────────────────────────────

verify_zeroclaw_url() {
    local url="$1"
    if [[ "$url" != *"github.com/zeroclaw-labs/zeroclaw"* ]]; then
        echo -e "  ${RED}[BLOCKED]${NC} URL does not match official zeroclaw-labs/zeroclaw"
        return 1
    fi
    for bad in "openagen" "zeroclaw.org" "zeroclaw.net"; do
        if [[ "$url" == *"$bad"* ]]; then
            echo -e "  ${RED}[BLOCKED]${NC} URL contains impersonator pattern '${bad}'"
            return 1
        fi
    done
    return 0
}

# ── Per-platform fetch ───────────────────────────────────────────────────────

fetch_nanoclaw() {
    echo -e "  ${BOLD}--- NanoClaw ---${NC}"
    local target="${REPOS_DIR}/nanoclaw"
    local repo="https://github.com/qwibitai/nanoclaw.git"
    mkdir -p "${REPOS_DIR}"

    if [[ -d "${target}/.git" ]]; then
        echo -e "  ${BOLD}[PULL]${NC} Updating..."
        git -C "${target}" pull --ff-only
        echo -e "  ${GREEN}[OK]${NC} Updated — $(git -C "${target}" branch --show-current) @ $(git -C "${target}" rev-parse --short HEAD)"
    else
        echo -e "  ${BOLD}[CLONE]${NC} Cloning ${repo}..."
        git clone "${repo}" "${target}"
        echo -e "  ${GREEN}[OK]${NC} Cloned @ $(git -C "${target}" rev-parse --short HEAD)"
    fi
}

fetch_zeroclaw() {
    echo -e "  ${BOLD}--- ZeroClaw (pre-built binary) ---${NC}"
    local target_dir="${REPOS_DIR}/zeroclaw"
    mkdir -p "${target_dir}"

    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="aarch64" ;;
        *)       echo -e "  ${RED}[ERROR]${NC} Unsupported arch: ${arch}"; return 1 ;;
    esac

    local url="https://github.com/zeroclaw-labs/zeroclaw/releases/latest/download/zeroclaw-linux-${arch}"
    verify_zeroclaw_url "$url" || return 1

    echo -e "  ${BOLD}[DOWNLOAD]${NC} ${url}..."
    if curl -fsSL "$url" -o "${target_dir}/zeroclaw"; then
        chmod 755 "${target_dir}/zeroclaw"
        echo -e "  ${GREEN}[OK]${NC} Binary downloaded ($(du -h "${target_dir}/zeroclaw" | cut -f1))"
    else
        echo -e "  ${YELLOW}[WARN]${NC} Download failed — platform script will retry during install"
    fi
}

fetch_openclaw() {
    echo -e "  ${BOLD}--- OpenClaw ---${NC}"
    echo -e "  ${YELLOW}[SKIP]${NC} OpenClaw is npm-installed — no repo to fetch"
}

fetch_ironclaw() {
    echo -e "  ${BOLD}--- IronClaw (pre-built binary) ---${NC}"
    local target_dir="${REPOS_DIR}/ironclaw"
    mkdir -p "${target_dir}"

    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="aarch64" ;;
        *)       echo -e "  ${RED}[ERROR]${NC} Unsupported arch: ${arch}"; return 1 ;;
    esac

    local url="https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-linux-${arch}"

    echo -e "  ${BOLD}[DOWNLOAD]${NC} ${url}..."
    if curl -fsSL "$url" -o "${target_dir}/ironclaw"; then
        chmod 755 "${target_dir}/ironclaw"
        echo -e "  ${GREEN}[OK]${NC} Binary downloaded ($(du -h "${target_dir}/ironclaw" | cut -f1))"
    else
        echo -e "  ${YELLOW}[WARN]${NC} Download failed — platform script will use installer during install"
    fi
}

# ── Status ───────────────────────────────────────────────────────────────────

show_status() {
    echo ""
    echo -e "${BOLD}  Fetch Status${NC}  (${REPOS_DIR})"
    echo ""

    # NanoClaw — git repo
    local nc_dir="${REPOS_DIR}/nanoclaw"
    if [[ -d "${nc_dir}/.git" ]]; then
        echo -e "  ${GREEN}[CLONED]${NC}   nanoclaw   $(git -C "${nc_dir}" branch --show-current 2>/dev/null) @ $(git -C "${nc_dir}" rev-parse --short HEAD 2>/dev/null)"
    else
        echo -e "  ${YELLOW}[ABSENT]${NC}  nanoclaw"
    fi

    # ZeroClaw — binary
    local zc_bin="${REPOS_DIR}/zeroclaw/zeroclaw"
    if [[ -x "$zc_bin" ]]; then
        echo -e "  ${GREEN}[BINARY]${NC}  zeroclaw   $(du -h "$zc_bin" | cut -f1)"
    else
        echo -e "  ${YELLOW}[ABSENT]${NC}  zeroclaw"
    fi

    # OpenClaw — npm
    echo -e "  ${GREEN}[NPM]${NC}     openclaw   (installed via npm)"

    # IronClaw — binary
    local ic_bin="${REPOS_DIR}/ironclaw/ironclaw"
    if [[ -x "$ic_bin" ]]; then
        echo -e "  ${GREEN}[BINARY]${NC}  ironclaw   $(du -h "$ic_bin" | cut -f1)"
    else
        echo -e "  ${YELLOW}[ABSENT]${NC}  ironclaw"
    fi

    echo ""
}

# ── Argument parsing ─────────────────────────────────────────────────────────

TARGETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status|-s)  STATUS_ONLY=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [PLATFORM...] [OPTIONS]

Platforms: nanoclaw, zeroclaw, openclaw, ironclaw
Options:   --status, -s   Show what's downloaded
           -h, --help     Show this help

Downloads go to: ${REPOS_DIR}/
EOF
            exit 0
            ;;
        nanoclaw|zeroclaw|openclaw|ironclaw)
            TARGETS+=("$1"); shift ;;
        *)
            echo -e "${RED}Unknown: $1${NC}"; exit 1 ;;
    esac
done

if $STATUS_ONLY; then
    show_status
    exit 0
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=("${ALL_PLATFORMS[@]}")
fi

# ── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}  Fetching: ${TARGETS[*]}${NC}"
echo ""

ERRORS=0
for target in "${TARGETS[@]}"; do
    if ! "fetch_${target}"; then
        ERRORS=$((ERRORS + 1))
    fi
    echo ""
done

if (( ERRORS > 0 )); then
    echo -e "${RED}${BOLD}FETCH COMPLETED WITH ${ERRORS} ERROR(S)${NC}"
    exit 1
else
    echo -e "${GREEN}${BOLD}FETCH COMPLETE${NC}"
fi
