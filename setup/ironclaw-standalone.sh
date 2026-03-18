#!/usr/bin/env bash
set -euo pipefail

# ironclaw-standalone.sh — From nothing to a running IronClaw service
#
# Uses Ollama (localhost) with qwen3-coder as the LLM backend.
# No API keys, no subscriptions, no browser auth.
#
# Usage:
#   sudo ./ironclaw-standalone.sh
#
# Prerequisites:
#   - Ollama running on localhost:11434 with qwen3-coder pulled
#
# To nuke and redo:
#   sudo pkill -9 -x ironclaw; sudo userdel -r izzy 2>/dev/null; sudo ./ironclaw-standalone.sh

# ── CONFIGURATION ────────────────────────────────────────────────────────────

USERNAME="izzy"
HOME_DIR="/home/${USERNAME}"
BIN_DIR="${HOME_DIR}/bin"
CARGO_BIN="${HOME_DIR}/.cargo/bin"
IRONCLAW_DIR="${HOME_DIR}/.ironclaw"
IRONCLAW_ENV="${IRONCLAW_DIR}/.env"
ENV_FILE="${HOME_DIR}/.env"

OLLAMA_MODEL="qwen3-coder"
OLLAMA_URL="http://127.0.0.1:11434"

# ── HELPERS ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}   $1"; }
info() { echo -e "  ${CYAN}[..]${NC}   $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1" >&2; exit 1; }
banner() { echo ""; echo -e "${BOLD}═══ $1 ═══${NC}"; echo ""; }

# ── ROOT CHECK ───────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    fail "Must run as root: sudo $0"
fi

echo ""
echo -e "${BOLD}IronClaw Standalone Setup${NC}"
echo -e "  User:  ${USERNAME}"
echo -e "  LLM:   Ollama → ${OLLAMA_MODEL}"
echo ""

# Kill any stale ironclaw processes (userdel -r doesn't kill running processes)
if pgrep -x ironclaw &>/dev/null; then
    info "Killing stale ironclaw processes..."
    pkill -x ironclaw 2>/dev/null || true
    sleep 2
    pkill -9 -x ironclaw 2>/dev/null || true
    ok "Stale processes cleaned up"
fi

# ── STEP 1: HOST DEPS ───────────────────────────────────────────────────────

banner "Step 1: Host Dependencies"

for pkg in curl git; do
    if command -v "$pkg" &>/dev/null; then
        ok "$pkg"
    else
        info "Installing $pkg..."
        apt-get install -y -qq "$pkg" || fail "$pkg install failed"
        ok "$pkg installed"
    fi
done

# Docker (optional — for shell sandbox)
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '')"
else
    warn "Docker not running — WASM tools work fine, shell sandbox won't"
fi

# Ollama
if curl -sf "${OLLAMA_URL}/api/version" &>/dev/null; then
    ok "Ollama running at ${OLLAMA_URL}"
else
    fail "Ollama not running at ${OLLAMA_URL} — start it first: systemctl start ollama"
fi

# Check model is pulled
if curl -sf "${OLLAMA_URL}/api/tags" | grep -q "${OLLAMA_MODEL}"; then
    ok "Model '${OLLAMA_MODEL}' available"
else
    fail "Model '${OLLAMA_MODEL}' not pulled — run: ollama pull ${OLLAMA_MODEL}"
fi

# ── STEP 2: CREATE USER ─────────────────────────────────────────────────────

banner "Step 2: Create User"

if id "$USERNAME" &>/dev/null; then
    ok "User '${USERNAME}' already exists"
else
    info "Creating user '${USERNAME}'..."
    useradd --create-home --shell /bin/bash --comment "IronClaw agent" "$USERNAME"
    ok "User '${USERNAME}' created"
fi

passwd -l "$USERNAME" &>/dev/null || true
chmod 700 "$HOME_DIR"

# Docker group (optional)
if getent group docker &>/dev/null; then
    if ! id -nG "$USERNAME" | grep -qw docker; then
        usermod -aG docker "$USERNAME"
        ok "Added to docker group"
    else
        ok "Already in docker group"
    fi
fi

# Directory structure
for dir in bin .config/systemd/user .local/bin .local/share .local/state .cache; do
    mkdir -p "${HOME_DIR}/${dir}"
done
ok "Directory structure"

# .profile
PROFILE="${HOME_DIR}/.profile"
MARKER="# IronClaw PATH setup"
if ! grep -qF "$MARKER" "$PROFILE" 2>/dev/null; then
    cat >> "$PROFILE" << 'PROFILE_EOF'

# IronClaw PATH setup
if [ -d "$HOME/bin" ]; then PATH="$HOME/bin:$PATH"; fi
if [ -d "$HOME/.local/bin" ]; then PATH="$HOME/.local/bin:$PATH"; fi
if [ -d "$HOME/.cargo/bin" ]; then PATH="$HOME/.cargo/bin:$PATH"; fi
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DO_NOT_TRACK=1
export EDITOR="nano"

# Source secrets
if [ -f "$HOME/.env" ]; then set -a; . "$HOME/.env"; set +a; fi
PROFILE_EOF
    ok ".profile"
else
    ok ".profile (already configured)"
fi

# Enable lingering (systemd user services survive logout)
loginctl enable-linger "$USERNAME" 2>/dev/null || true
ok "Lingering enabled"

chown -R "${USERNAME}:${USERNAME}" "$HOME_DIR"
ok "Ownership set"

# ── STEP 3: SECRETS FILE ────────────────────────────────────────────────────

banner "Step 3: Secrets"

if [[ -f "$ENV_FILE" ]]; then
    ok "${ENV_FILE} already exists"
    chmod 600 "$ENV_FILE"
else
    cat > "$ENV_FILE" << 'ENV_EOF'
# Secrets for izzy (IronClaw)
# chmod 600 — only izzy can read.
#
# Telegram (optional):
# TELEGRAM_BOT_TOKEN=...
ENV_EOF
    chmod 600 "$ENV_FILE"
    chown "${USERNAME}:${USERNAME}" "$ENV_FILE"
    ok "Created ${ENV_FILE}"
fi

# Check for Telegram token
TELEGRAM_BOT_TOKEN=""
set +u
set -a; source "$ENV_FILE" 2>/dev/null; set +a
set -u

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    ok "Telegram: configured"
else
    info "Telegram: not configured (optional)"
fi

# ── STEP 4: INSTALL BINARY ──────────────────────────────────────────────────

banner "Step 4: Install IronClaw Binary"

if [[ -x "${BIN_DIR}/ironclaw" ]]; then
    ver="$("${BIN_DIR}/ironclaw" --version 2>/dev/null || echo 'unknown')"
    ok "Already installed: ${ver}"
elif [[ -x "${CARGO_BIN}/ironclaw" ]]; then
    ln -sf "${CARGO_BIN}/ironclaw" "${BIN_DIR}/ironclaw"
    ver="$("${BIN_DIR}/ironclaw" --version 2>/dev/null || echo 'unknown')"
    ok "Symlinked existing: ${ver}"
else
    info "Downloading via official installer..."
    INSTALLER_URL="https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-installer.sh"
    su - "$USERNAME" -c "curl --proto '=https' --tlsv1.2 -LsSf '${INSTALLER_URL}' | sh" 2>&1

    if [[ -x "${CARGO_BIN}/ironclaw" ]]; then
        ln -sf "${CARGO_BIN}/ironclaw" "${BIN_DIR}/ironclaw"
        chown "${USERNAME}:${USERNAME}" "${BIN_DIR}/ironclaw"
        ver="$("${BIN_DIR}/ironclaw" --version 2>/dev/null || echo 'unknown')"
        ok "Installed: ${ver}"
    else
        fail "Binary not found after install — check output above"
    fi
fi

# ── STEP 5: WRITE IRONCLAW CONFIG ───────────────────────────────────────────

banner "Step 5: Write IronClaw Config"

mkdir -p "${IRONCLAW_DIR}/channels" "${IRONCLAW_DIR}/tools"

# Find a free port for the webhook server (scan 8090-8110)
IRONCLAW_HTTP_PORT=""
for port in $(seq 8090 8110); do
    if ! ss -tln | grep -q ":${port} "; then
        IRONCLAW_HTTP_PORT="$port"
        break
    fi
done
if [[ -z "$IRONCLAW_HTTP_PORT" ]]; then
    fail "No free port found in 8090-8110 range"
fi
ok "Webhook port: ${IRONCLAW_HTTP_PORT}"

# Get Tailscale IP
TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"
if [[ -z "$TAILSCALE_IP" ]]; then
    fail "Tailscale not running — need tailnet IP for binding"
fi
ok "Tailscale IP: ${TAILSCALE_IP}"

# Generate secrets
IRONCLAW_WEBHOOK_SECRET="$(openssl rand -hex 32)"
IRONCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
ok "Secrets generated"

cat > "$IRONCLAW_ENV" << EOF
# IronClaw bootstrap config
# Loaded BEFORE database. Priority: env var > TOML > DB > defaults

# ── Database (libsql = zero-config) ──
DATABASE_BACKEND=libsql
LIBSQL_PATH=${IRONCLAW_DIR}/ironclaw.db

# ── LLM: Ollama (local, no API keys) ──
LLM_BACKEND=ollama
OLLAMA_MODEL=${OLLAMA_MODEL}
OLLAMA_BASE_URL=${OLLAMA_URL}

# ── HTTP webhook server ──
HTTP_HOST=${TAILSCALE_IP}
HTTP_PORT=${IRONCLAW_HTTP_PORT}
HTTP_WEBHOOK_SECRET=${IRONCLAW_WEBHOOK_SECRET}

# ── Web gateway (browser chat UI) ──
GATEWAY_HOST=${TAILSCALE_IP}
GATEWAY_PORT=1111
GATEWAY_AUTH_TOKEN=${IRONCLAW_GATEWAY_TOKEN}

# ── Headless mode (no stdin, no browser, no interactive prompts) ──
ONBOARD_COMPLETED=true
CLI_ENABLED=true

# ── Sandbox ──
WASM_ENABLED=true
WASM_DEFAULT_TIMEOUT_SECS=60
SANDBOX_ENABLED=true
SANDBOX_POLICY=readonly

# ── Agent ──
AGENT_NAME=ironclaw
AGENT_USE_PLANNING=true

# ── Logging ──
RUST_LOG=ironclaw=info
EOF

chmod 600 "$IRONCLAW_ENV"
chown -R "${USERNAME}:${USERNAME}" "$IRONCLAW_DIR"
ok "Config written to ${IRONCLAW_ENV}"

# Clean any stale PID file (left by crashed/killed previous runs)
rm -f "${IRONCLAW_DIR}/ironclaw.pid"

# ── STEP 5b: INSTALL EXTENSIONS ─────────────────────────────────────────────

banner "Step 5b: Install Extensions"

# Install Telegram channel and default extensions from the built-in registry
info "Installing Telegram channel..."
su - "$USERNAME" -c "IRONCLAW_BASE_DIR=${IRONCLAW_DIR} ${BIN_DIR}/ironclaw registry install telegram" 2>&1 && ok "Telegram channel installed" || warn "Telegram channel install failed"

info "Installing default extensions..."
su - "$USERNAME" -c "IRONCLAW_BASE_DIR=${IRONCLAW_DIR} ${BIN_DIR}/ironclaw registry install-defaults" 2>&1 && ok "Default extensions installed" || warn "Default extensions install failed"

# ── STEP 6: SYSTEMD SERVICE ─────────────────────────────────────────────────

banner "Step 6: Systemd Service"

SVC_DIR="${HOME_DIR}/.config/systemd/user"
SVC_FILE="${SVC_DIR}/ironclaw.service"
SVC_PATH="${BIN_DIR}:${CARGO_BIN}:${HOME_DIR}/.local/bin:/usr/local/bin:/usr/bin:/bin"

cat > "$SVC_FILE" << EOF
[Unit]
Description=IronClaw AI Agent
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/ironclaw run --no-onboard
Restart=on-failure
RestartSec=10

# Load secrets first, then ironclaw config (later values win)
EnvironmentFile=${ENV_FILE}
EnvironmentFile=${IRONCLAW_ENV}

# Headless — no interactive stdin, no browser auth
Environment=CLI_ENABLED=true
Environment=ONBOARD_COMPLETED=true
Environment=PATH=${SVC_PATH}
Environment=IRONCLAW_BASE_DIR=${IRONCLAW_DIR}
Environment=HOME=${HOME_DIR}

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${IRONCLAW_DIR}
PrivateTmp=true

[Install]
WantedBy=default.target
EOF

chown "${USERNAME}:${USERNAME}" "$SVC_FILE"
ok "Service file written"

# Start the service
IZZY_UID=$(id -u "$USERNAME")
XDG="/run/user/${IZZY_UID}"

if [[ ! -d "$XDG" ]]; then
    warn "XDG_RUNTIME_DIR not yet created — service will start on next login or reboot"
    echo ""
    echo -e "  ${BOLD}To start now:${NC}"
    echo "    sudo -iu ${USERNAME} bash -c 'systemctl --user daemon-reload && systemctl --user enable --now ironclaw'"
else
    info "Starting service..."
    if su - "$USERNAME" -c "XDG_RUNTIME_DIR=${XDG} DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG}/bus systemctl --user daemon-reload && XDG_RUNTIME_DIR=${XDG} DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG}/bus systemctl --user enable --now ironclaw" 2>&1; then
        ok "Service started"
    else
        warn "Could not auto-start — run manually:"
        echo "    sudo -iu ${USERNAME} bash -c 'systemctl --user daemon-reload && systemctl --user enable --now ironclaw'"
    fi
fi

# ── STEP 7: VERIFY ──────────────────────────────────────────────────────────

banner "Step 7: Verify"

if "${BIN_DIR}/ironclaw" --version &>/dev/null; then
    ok "Binary: $("${BIN_DIR}/ironclaw" --version 2>/dev/null)"
else
    warn "Binary not responding"
fi

[[ -f "$IRONCLAW_ENV" ]] && ok "Config: ${IRONCLAW_ENV}" || warn "Config missing"
[[ -f "$ENV_FILE" ]]     && ok "Secrets: ${ENV_FILE}" || warn "Secrets missing"
[[ -f "$SVC_FILE" ]]     && ok "Service: ${SVC_FILE}" || warn "Service file missing"

if [[ -d "$XDG" ]]; then
    svc_state=$(su - "$USERNAME" -c "XDG_RUNTIME_DIR=${XDG} DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG}/bus systemctl --user is-active ironclaw 2>/dev/null" || echo "unknown")
    if [[ "$svc_state" == "active" ]]; then
        ok "Service: running"
    else
        warn "Service: ${svc_state}"
    fi
fi

# ── DONE ─────────────────────────────────────────────────────────────────────

banner "Done"

echo -e "  ${GREEN}${BOLD}IronClaw is set up for user '${USERNAME}'${NC}"
echo ""
echo -e "  ${BOLD}LLM:${NC}      Ollama → ${OLLAMA_MODEL} (${OLLAMA_URL})"
echo ""
echo -e "  ${BOLD}Chat:${NC}"
echo "    Web UI:  http://${TAILSCALE_IP}:1111?token=${IRONCLAW_GATEWAY_TOKEN}"
echo "    CLI:     sudo -iu ${USERNAME} ironclaw run --no-onboard  (stop service first)"
echo ""
echo -e "  ${BOLD}Commands:${NC}"
echo "    Logs:    sudo -iu ${USERNAME} journalctl --user -u ironclaw -f"
echo "    Status:  sudo -iu ${USERNAME} systemctl --user status ironclaw"
echo "    Restart: sudo -iu ${USERNAME} systemctl --user restart ironclaw"
echo "    Stop:    sudo -iu ${USERNAME} systemctl --user stop ironclaw"
echo ""
echo -e "  ${BOLD}Files:${NC}"
echo "    Secrets:  ${ENV_FILE}       (telegram token, etc.)"
echo "    Config:   ${IRONCLAW_ENV}"
echo "    Database: ${IRONCLAW_DIR}/ironclaw.db"
echo "    Service:  ${SVC_FILE}"
echo ""
echo -e "  ${BOLD}To nuke and redo:${NC}"
echo "    sudo pkill -9 -x ironclaw; sudo userdel -r ${USERNAME}; sudo $0"
echo ""
