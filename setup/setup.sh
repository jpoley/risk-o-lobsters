#!/usr/bin/env bash
set -euo pipefail

# setup.sh — One-command setup for Claw platforms (fetch + deploy)
#
# Usage:
#   ./setup.sh nanoclaw                         # Fetch + deploy, uses default name
#   ./setup.sh nanoclaw --as nora               # Fetch + deploy as "nora"
#   ./setup.sh nanoclaw ironclaw                # Two platforms
#   ./setup.sh                                  # All 4 platforms
#   ./setup.sh --list                           # Show status
#   ./setup.sh --dry-run nanoclaw               # Preview
#
# Fetch runs as current user. Deploy escalates to sudo when needed.
# User names must start with the same letter as the platform:
#   nanoclaw → n*    zeroclaw → z*    openclaw → o*    ironclaw → i*

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/../.platform-users"
DRY_RUN=false
LIST_ONLY=false

ALL_PLATFORMS=(nanoclaw zeroclaw openclaw ironclaw)

declare -A PLATFORM_DISPLAY=(
    [nanoclaw]="NanoClaw"  [zeroclaw]="ZeroClaw"
    [openclaw]="OpenClaw"  [ironclaw]="IronClaw"
)

declare -A PLATFORM_LETTER=(
    [nanoclaw]="n"  [zeroclaw]="z"  [openclaw]="o"  [ironclaw]="i"
)

declare -A NAME_POOL=(
    [nanoclaw]="nancy nora niko nina noah natasha neil"
    [zeroclaw]="zlatan zara zoe zach zena zeke zuri"
    [openclaw]="ollie oscar olive owen ora otto opal"
    [ironclaw]="izzy ivan iris isla igor ida ike"
)

# ── State file ───────────────────────────────────────────────────────────────

load_user_for() {
    local platform="$1"
    if [[ -f "$STATE_FILE" ]]; then
        grep -m1 "^${platform}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true
    fi
}

# ── Name resolution: --as > state file > interactive pick ────────────────────

resolve_or_suggest() {
    local platform="$1" explicit="${2:-}"
    local letter="${PLATFORM_LETTER[$platform]}"
    local pool="${NAME_POOL[$platform]}"
    local default_name; default_name="$(echo "$pool" | cut -d' ' -f1)"

    # 1. Explicit --as
    if [[ -n "$explicit" ]]; then
        if [[ "${explicit:0:1}" != "$letter" ]]; then
            echo -e "${RED}ERROR: Name for ${PLATFORM_DISPLAY[$platform]} must start with '${letter}'${NC}" >&2
            echo -e "${CYAN}Pick one: ${pool}${NC}" >&2
            return 1
        fi
        echo "$explicit"
        return 0
    fi

    # 2. Previously saved
    local saved; saved="$(load_user_for "$platform")"
    if [[ -n "$saved" ]]; then
        echo "$saved"
        return 0
    fi

    # 3. Interactive — suggest from pool
    if [[ -t 0 ]]; then
        echo "" >&2
        echo -e "${BOLD}Choose a name for ${PLATFORM_DISPLAY[$platform]}${NC} (must start with '${letter}'):" >&2
        echo -e "${CYAN}  Suggestions: ${pool}${NC}" >&2
        echo -en "${BOLD}  Name [${default_name}]: ${NC}" >&2
        read -r chosen
        chosen="${chosen:-$default_name}"
        if [[ "${chosen:0:1}" != "$letter" ]]; then
            echo -e "${RED}ERROR: '${chosen}' doesn't start with '${letter}'${NC}" >&2
            return 1
        fi
        echo "$chosen"
        return 0
    fi

    # 4. Non-interactive fallback
    echo "$default_name"
}

# ── Argument parsing ─────────────────────────────────────────────────────────

TARGETS=()
declare -A TARGET_USERS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --list|-l)  LIST_ONLY=true; shift ;;
        --as)
            if [[ ${#TARGETS[@]} -eq 0 ]]; then
                echo -e "${RED}--as must follow a platform name${NC}"; exit 1
            fi
            TARGET_USERS["${TARGETS[-1]}"]="${2:?--as requires a name}"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: ./setup.sh [PLATFORM [--as NAME]]... [OPTIONS]

Platforms:
  nanoclaw    NanoClaw  (Anthropic, Docker, Node.js)     name starts with 'n'
  zeroclaw    ZeroClaw  (OpenRouter, Landlock)            name starts with 'z'
  openclaw    OpenClaw  (Multi-provider, Node.js)         name starts with 'o'
  ironclaw    IronClaw  (NEAR AI, PostgreSQL, WASM)       name starts with 'i'

Options:
  --as NAME     Set the Linux username (must match first letter)
  --dry-run     Preview without making changes
  --list, -l    Show status of all platforms
  -h, --help    Show this help

Examples:
  ./setup.sh nanoclaw                              # Prompted for name
  ./setup.sh nanoclaw --as nora                    # NanoClaw as "nora"
  ./setup.sh nanoclaw --as nora ironclaw --as ivan # Two with names
  ./setup.sh                                       # All 4, prompted
  ./setup.sh --list                                # Check status
EOF
            exit 0
            ;;
        nanoclaw|zeroclaw|openclaw|ironclaw)
            TARGETS+=("$1"); shift ;;
        *)
            echo -e "${RED}Unknown: $1${NC}"
            echo "Valid platforms: ${ALL_PLATFORMS[*]}"
            exit 1
            ;;
    esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=("${ALL_PLATFORMS[@]}")
fi

# ── --list: passthrough to install.sh ────────────────────────────────────────

if $LIST_ONLY; then
    if [[ $EUID -ne 0 ]]; then
        exec sudo bash "${SCRIPT_DIR}/install.sh" --list
    else
        exec bash "${SCRIPT_DIR}/install.sh" --list
    fi
fi

# ── Resolve all names upfront ────────────────────────────────────────────────

declare -A RESOLVED=()
for platform in "${TARGETS[@]}"; do
    explicit="${TARGET_USERS[$platform]:-}"
    if ! username="$(resolve_or_suggest "$platform" "$explicit")"; then
        exit 1
    fi
    RESOLVED[$platform]="$username"
done

# Confirm plan
echo ""
echo -e "${BOLD}  Setup Plan${NC}"
echo ""
for platform in "${TARGETS[@]}"; do
    echo -e "    ${PLATFORM_DISPLAY[$platform]}  →  ${CYAN}${RESOLVED[$platform]}${NC}"
done
echo ""

if [[ -t 0 ]] && ! $DRY_RUN; then
    echo -en "${BOLD}  Proceed? [Y/n]: ${NC}"
    read -r confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ── Step 1: Fetch (no root needed) ──────────────────────────────────────────

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  Step 1: Fetch${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

if $DRY_RUN; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would run: fetch.sh ${TARGETS[*]}"
else
    bash "${SCRIPT_DIR}/fetch.sh" "${TARGETS[@]}"
fi

# ── Step 2: Install (needs root) ────────────────────────────────────────────

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  Step 2: Install (requires sudo)${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

INSTALL_ARGS=()
$DRY_RUN && INSTALL_ARGS+=("--dry-run")

for platform in "${TARGETS[@]}"; do
    INSTALL_ARGS+=("$platform" "--as" "${RESOLVED[$platform]}")
done

if [[ $EUID -ne 0 ]]; then
    sudo bash "${SCRIPT_DIR}/install.sh" "${INSTALL_ARGS[@]}"
else
    bash "${SCRIPT_DIR}/install.sh" "${INSTALL_ARGS[@]}"
fi
