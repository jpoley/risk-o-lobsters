#!/usr/bin/env bash
set -euo pipefail

# reset.sh — Nuke a platform user and rebuild from scratch
#
# Usage:
#   ./reset.sh zeroclaw                     # Uses default user (zlatan)
#   ./reset.sh zeroclaw --as zlatan         # Explicit user
#
# Secrets are read from the caller's environment via setup/env-map.sh (gitignored).
# env-map.sh maps your personal env var names to the standard names:
#   OPENROUTER_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USER_ID
#
# Secrets are written ONLY to the platform user's ~/.env (chmod 600). Never to the repo.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
STATE_FILE="${ROOT_DIR}/.platform-users"

ALL_PLATFORMS=(nanoclaw zeroclaw openclaw ironclaw)

declare -A PLATFORM_LETTER=(
    [nanoclaw]="n"  [zeroclaw]="z"  [openclaw]="o"  [ironclaw]="i"
)

declare -A PLATFORM_DEFAULT_USER=(
    [nanoclaw]="nancy"  [zeroclaw]="zlatan"  [openclaw]="ollie"  [ironclaw]="izzy"
)

declare -A PLATFORM_DOCKER=(
    [nanoclaw]="yes"  [zeroclaw]="no"  [openclaw]="no"  [ironclaw]="yes"
)

# ── Source env mapping (gitignored, operator-specific) ────────────────────────
[[ -f "${SCRIPT_DIR}/env-map.sh" ]] && source "${SCRIPT_DIR}/env-map.sh"

# Which env vars each platform needs in the user's ~/.env
declare -A PLATFORM_ENV_VARS=(
    [nanoclaw]="ANTHROPIC_API_KEY TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_ID"
    [zeroclaw]="OPENROUTER_API_KEY TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_ID"
    [openclaw]="OPENROUTER_API_KEY TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_ID"
    [ironclaw]="ANTHROPIC_API_KEY TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_ID"
)

usage() {
    cat <<'EOF'
Usage: ./reset.sh <platform> [--as <username>]

Platforms: nanoclaw, zeroclaw, openclaw, ironclaw

Options:
  --as NAME     Override the Linux username (must match platform's first letter)

Example:
  ./reset.sh zeroclaw
  ./reset.sh zeroclaw --as zlatan
EOF
    exit 1
}

fatal() { echo -e "${RED}FATAL: $1${NC}" >&2; exit 1; }

# ── Argument parsing ─────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && usage

PLATFORM="$1"; shift
EXPLICIT_USER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --as) EXPLICIT_USER="${2:?--as requires a name}"; shift 2 ;;
        -h|--help) usage ;;
        *) fatal "Unknown option: $1" ;;
    esac
done

# Validate platform
printf '%s\n' "${ALL_PLATFORMS[@]}" | grep -qx "$PLATFORM" || fatal "Unknown platform: ${PLATFORM}"

# ── Resolve username ─────────────────────────────────────────────────────────

LETTER="${PLATFORM_LETTER[$PLATFORM]}"

if [[ -n "$EXPLICIT_USER" ]]; then
    [[ "${EXPLICIT_USER:0:1}" == "$LETTER" ]] || fatal "Username for ${PLATFORM} must start with '${LETTER}'"
    USERNAME="$EXPLICIT_USER"
elif [[ -f "$STATE_FILE" ]]; then
    USERNAME="$(grep -m1 "^${PLATFORM}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)"
    USERNAME="${USERNAME:-${PLATFORM_DEFAULT_USER[$PLATFORM]}}"
else
    USERNAME="${PLATFORM_DEFAULT_USER[$PLATFORM]}"
fi

# ── Validate secrets ─────────────────────────────────────────────────────────

REQUIRED_VARS="${PLATFORM_ENV_VARS[$PLATFORM]}"
MISSING=()
for var in $REQUIRED_VARS; do
    if [[ -z "${!var:-}" ]]; then
        MISSING+=("$var")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e "${RED}Missing env vars: ${MISSING[*]}${NC}" >&2
    echo "Export them before running this script." >&2
    exit 1
fi

# ── Confirm ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}  Reset Plan${NC}"
echo ""
echo -e "    Platform:  ${PLATFORM}"
echo -e "    User:      ${USERNAME}"
echo -e "    Action:    DELETE user + home, rebuild from scratch"
echo ""

if [[ -t 0 ]]; then
    echo -en "${BOLD}  This will destroy /home/${USERNAME}. Proceed? [y/N]: ${NC}"
    read -r confirm
    [[ "$confirm" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
fi

# ── Phase 1: Nuke ────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}=== Phase 1: Nuke ===${NC}"

sudo bash -c "
    # Stop user services
    if id '${USERNAME}' &>/dev/null; then
        XDG=/run/user/\$(id -u '${USERNAME}')
        sudo -u '${USERNAME}' XDG_RUNTIME_DIR=\$XDG systemctl --user stop '${PLATFORM}' 2>/dev/null || true
        loginctl disable-linger '${USERNAME}' 2>/dev/null || true
        pkill -u '${USERNAME}' 2>/dev/null || true
        sleep 1
        pkill -9 -u '${USERNAME}' 2>/dev/null || true
    fi
    userdel -r '${USERNAME}' 2>/dev/null || true
    rm -rf '/home/${USERNAME}'
"
echo -e "${GREEN}✓ ${USERNAME} removed${NC}"

# ── Phase 2: Fetch ───────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}=== Phase 2: Fetch ===${NC}"
bash "${SCRIPT_DIR}/fetch.sh" "$PLATFORM"

# ── Phase 3: Install (creates user + runs platform script) ───────────────────

echo ""
echo -e "${BOLD}=== Phase 3: Install ===${NC}"
sudo bash "${SCRIPT_DIR}/install.sh" "$PLATFORM" --as "$USERNAME"

# ── Phase 4: Write secrets ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}=== Phase 4: Secrets ===${NC}"

ENV_CONTENT=""
for var in $REQUIRED_VARS; do
    ENV_CONTENT+="${var}=${!var}"$'\n'
done

sudo bash -c "
    cat > '/home/${USERNAME}/.env' <<'ENVEOF'
${ENV_CONTENT}ENVEOF
    chmod 600 '/home/${USERNAME}/.env'
    chown '${USERNAME}:${USERNAME}' '/home/${USERNAME}/.env'
"
echo -e "${GREEN}✓ secrets written to /home/${USERNAME}/.env${NC}"

# ── Phase 5: Re-run platform config (picks up secrets) ──────────────────────

echo ""
echo -e "${BOLD}=== Phase 5: Configure ===${NC}"

sudo bash -c "
    cp '${SCRIPT_DIR}/platforms/${PLATFORM}.sh' '/home/${USERNAME}/.reconfig.sh'
    chown '${USERNAME}:${USERNAME}' '/home/${USERNAME}/.reconfig.sh'
"
sudo machinectl shell "${USERNAME}@" /bin/bash -c 'source ~/.profile && bash ~/.reconfig.sh && rm ~/.reconfig.sh'

# ── Phase 5b: Telegram setup script ──────────────────────────────────────────

echo ""
echo -e "${BOLD}=== Phase 5b: Deploy telegram setup ===${NC}"

sudo tee "/home/${USERNAME}/setup-telegram.sh" > /dev/null <<TGEOF
#!/bin/bash
source ~/.profile
set -e
BOT_TOKEN="\$(grep TELEGRAM_BOT_TOKEN ~/.env | cut -d= -f2)"
USER_ID="\$(grep TELEGRAM_ALLOWED_USER_ID ~/.env | cut -d= -f2)"
echo "Adding telegram channel..."
zeroclaw channel add telegram "{\"bot_token\":\"\${BOT_TOKEN}\",\"name\":\"${PLATFORM}-bot\"}"
echo "Binding telegram user \${USER_ID}..."
zeroclaw channel bind-telegram "\${USER_ID}"
echo "Verifying..."
zeroclaw channel list
TGEOF
sudo chmod 700 "/home/${USERNAME}/setup-telegram.sh"
sudo chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/setup-telegram.sh"
echo -e "${GREEN}✓ /home/${USERNAME}/setup-telegram.sh deployed${NC}"

# ── Phase 6: Start service ──────────────────────────────────────────────────

echo ""
echo -e "${BOLD}=== Phase 6: Start ===${NC}"

sudo machinectl shell "${USERNAME}@" /bin/bash -c "source ~/.profile && systemctl --user daemon-reload && systemctl --user enable --now ${PLATFORM}"

# ── Phase 7: Verify ─────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}=== Verify ===${NC}"

sudo machinectl shell "${USERNAME}@" /bin/bash -c "source ~/.profile && systemctl --user status ${PLATFORM} --no-pager"

echo ""
echo -e "${GREEN}${BOLD}✓ ${PLATFORM} running as ${USERNAME}${NC}"
echo ""
