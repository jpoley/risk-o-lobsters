#!/usr/bin/env bash
set -euo pipefail

# setup-telegram.sh — Configure Telegram for a platform user
#
# Usage:
#   ./setup-telegram.sh zeroclaw
#   ./setup-telegram.sh zeroclaw --as zlatan
#
# Deploys a script into the user's home and runs it via machinectl.
# Secrets read from env-map.sh (gitignored).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/../.platform-users"

[[ -f "${SCRIPT_DIR}/env-map.sh" ]] && source "${SCRIPT_DIR}/env-map.sh"

declare -A PLATFORM_DEFAULT_USER=(
    [nanoclaw]="nancy" [zeroclaw]="zlatan" [openclaw]="ollie" [ironclaw]="izzy"
)

[[ $# -lt 1 ]] && { echo "Usage: $0 <platform> [--as <username>]"; exit 1; }

PLATFORM="$1"; shift
USERNAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --as) USERNAME="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "$USERNAME" ]]; then
    if [[ -f "$STATE_FILE" ]]; then
        USERNAME="$(grep -m1 "^${PLATFORM}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)"
    fi
    USERNAME="${USERNAME:-${PLATFORM_DEFAULT_USER[$PLATFORM]:-}}"
fi

[[ -z "$USERNAME" ]] && { echo "Cannot resolve username for ${PLATFORM}"; exit 1; }
[[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && { echo "TELEGRAM_BOT_TOKEN not set"; exit 1; }
[[ -z "${TELEGRAM_ALLOWED_USER_ID:-}" ]] && { echo "TELEGRAM_ALLOWED_USER_ID not set"; exit 1; }

SCRIPT_PATH="/home/${USERNAME}/.setup-telegram.sh"

sudo tee "$SCRIPT_PATH" > /dev/null <<ENDSCRIPT
#!/bin/bash
source ~/.profile
set -e
echo "Running: zeroclaw onboard --channels-only --force"
zeroclaw onboard --channels-only --force
echo "Running: zeroclaw channel bind-telegram ${TELEGRAM_ALLOWED_USER_ID}"
zeroclaw channel bind-telegram "${TELEGRAM_ALLOWED_USER_ID}"
echo "Verifying..."
zeroclaw channel list
ENDSCRIPT

sudo chmod 700 "$SCRIPT_PATH"
sudo chown "${USERNAME}:${USERNAME}" "$SCRIPT_PATH"

echo "Running telegram setup as ${USERNAME}..."
sudo machinectl shell "${USERNAME}@" /bin/bash -c "bash ${SCRIPT_PATH} && rm ${SCRIPT_PATH}"
