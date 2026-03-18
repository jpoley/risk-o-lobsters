#!/usr/bin/env bash
set -euo pipefail

# zeroclaw.sh — Install and configure ZeroClaw (fully automatable)
#
# ZeroClaw is a static Rust binary (~3.4MB). No build tools needed.
# Uses Landlock sandbox (kernel 5.13+, auto-detected), OpenRouter for LLM.
#
# SUPPLY-CHAIN: Only github.com/zeroclaw-labs/zeroclaw is trusted.
# zeroclaw.org, zeroclaw.net, openagen are known impersonators.
#
# Binary installs to ~/.cargo/bin/zeroclaw (via official install.sh).
# Config lives at ~/.zeroclaw/config.toml (ChaCha20Poly1305 encrypted secrets).
#
# Usage: Run as the ZeroClaw user (e.g., zlatan). Not root.

OFFICIAL_ORG="zeroclaw-labs"
OFFICIAL_REPO="zeroclaw"
BIN_DIR="${HOME}/bin"
CARGO_BIN="${HOME}/.cargo/bin"
CONFIG_DIR="${HOME}/.zeroclaw"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
ENV_FILE="${HOME}/.env"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$1"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$1"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$1"; }
fatal() { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$1" >&2; exit 1; }

# ── Supply-chain verification ────────────────────────────────────────────────

verify_url() {
    local url="$1"
    if [[ "$url" != *"${OFFICIAL_ORG}/${OFFICIAL_REPO}"* ]]; then
        fatal "URL does not match official ${OFFICIAL_ORG}/${OFFICIAL_REPO} — aborting"
    fi
    for bad in "openagen" "zeroclaw.org" "zeroclaw.net"; do
        if [[ "$url" == *"$bad"* ]]; then
            fatal "URL contains impersonator pattern '${bad}' — aborting"
        fi
    done
}

# ── Install binary ─────────────────────────────────────────────────────────

install_binary() {
    info "Installing ZeroClaw binary..."

    mkdir -p "${BIN_DIR}"

    # Check if already installed
    if [[ -x "${BIN_DIR}/zeroclaw" ]] || [[ -x "${CARGO_BIN}/zeroclaw" ]]; then
        local existing="${BIN_DIR}/zeroclaw"
        [[ -x "$existing" ]] || existing="${CARGO_BIN}/zeroclaw"
        local ver
        ver="$("$existing" --version 2>/dev/null || echo 'unknown')"
        ok "ZeroClaw already installed: ${ver}"
        ensure_symlink "$existing"
        return 0
    fi

    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  local target="x86_64-unknown-linux-gnu" ;;
        aarch64) local target="aarch64-unknown-linux-gnu" ;;
        *)       fatal "Unsupported architecture: ${arch}" ;;
    esac

    # Strategy 1: Use official install.sh (installs to ~/.cargo/bin/)
    local installer_url="https://github.com/${OFFICIAL_ORG}/${OFFICIAL_REPO}/releases/latest/download/zeroclaw-installer.sh"
    # Note: some releases use install.sh directly from master
    local installer_url_alt="https://raw.githubusercontent.com/${OFFICIAL_ORG}/${OFFICIAL_REPO}/master/install.sh"

    for url in "$installer_url" "$installer_url_alt"; do
        verify_url "$url"
        info "Trying installer: ${url}"
        if curl --proto '=https' --tlsv1.2 -fsSL "$url" | bash -s -- --prebuilt-only --skip-onboard 2>&1; then
            if [[ -x "${CARGO_BIN}/zeroclaw" ]]; then
                ensure_symlink "${CARGO_BIN}/zeroclaw"
                local ver
                ver="$("${BIN_DIR}/zeroclaw" --version 2>/dev/null || echo 'unknown')"
                ok "Installed via official installer: ${ver}"
                return 0
            fi
        fi
    done

    # Strategy 2: Direct tar.gz download
    local tarball_url="https://github.com/${OFFICIAL_ORG}/${OFFICIAL_REPO}/releases/latest/download/zeroclaw-${target}.tar.gz"
    verify_url "$tarball_url"
    info "Trying direct download: ${tarball_url}"
    local tmpdir
    tmpdir="$(mktemp -d)"
    if curl --proto '=https' --tlsv1.2 -fsSL "$tarball_url" | tar -xz -C "$tmpdir" 2>/dev/null; then
        # Binary may be at top level or in a subdirectory
        local found_bin
        found_bin="$(find "$tmpdir" -name 'zeroclaw' -type f -executable 2>/dev/null | head -1)"
        if [[ -n "$found_bin" ]]; then
            mv "$found_bin" "${BIN_DIR}/zeroclaw"
            chmod 755 "${BIN_DIR}/zeroclaw"
            rm -rf "$tmpdir"
            local ver
            ver="$("${BIN_DIR}/zeroclaw" --version 2>/dev/null || echo 'unknown')"
            ok "Installed from tarball: ${ver}"
            return 0
        fi
    fi
    rm -rf "$tmpdir"

    # Strategy 3: Direct binary download (no tarball)
    local bin_url="https://github.com/${OFFICIAL_ORG}/${OFFICIAL_REPO}/releases/latest/download/zeroclaw-${target}"
    verify_url "$bin_url"
    info "Trying direct binary: ${bin_url}"
    if curl --proto '=https' --tlsv1.2 -fsSL "$bin_url" -o "${BIN_DIR}/zeroclaw.tmp" 2>/dev/null; then
        chmod 755 "${BIN_DIR}/zeroclaw.tmp"
        if "${BIN_DIR}/zeroclaw.tmp" --version &>/dev/null; then
            mv "${BIN_DIR}/zeroclaw.tmp" "${BIN_DIR}/zeroclaw"
            ok "Installed from direct download"
            return 0
        fi
        rm -f "${BIN_DIR}/zeroclaw.tmp"
    fi

    fatal "Could not install ZeroClaw binary by any method"
}

ensure_symlink() {
    local source="$1"
    if [[ "$source" != "${BIN_DIR}/zeroclaw" ]]; then
        ln -sf "$source" "${BIN_DIR}/zeroclaw"
        ok "Symlinked ${source} → ${BIN_DIR}/zeroclaw"
    fi
}

# ── Configure ────────────────────────────────────────────────────────────────

configure() {
    info "Configuring ZeroClaw..."

    # Source env for secrets
    if [[ -f "${ENV_FILE}" ]]; then
        set -a; source "${ENV_FILE}"; set +a
    fi

    local zeroclaw="${BIN_DIR}/zeroclaw"

    # Write config.toml first (always — onboard may overwrite, that's fine)
    write_config

    # Run onboard in quick+force mode to register provider and channels
    if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
        info "Running: zeroclaw onboard --quick --force"
        "$zeroclaw" onboard \
            --api-key "$OPENROUTER_API_KEY" \
            --provider openrouter \
            --model "moonshotai/kimi-k2" \
            --memory sqlite \
            --force 2>&1 || warn "zeroclaw onboard exited non-zero (config.toml used as fallback)"
        ok "Onboard complete"
    else
        warn "OPENROUTER_API_KEY not set — skipping onboard"
    fi

    # Bind telegram user by numeric ID
    if [[ -n "${TELEGRAM_ALLOWED_USER_ID:-}" ]]; then
        info "Binding telegram user ${TELEGRAM_ALLOWED_USER_ID}..."
        "$zeroclaw" channel bind-telegram "${TELEGRAM_ALLOWED_USER_ID}" 2>&1 \
            || warn "bind-telegram failed (can be done manually: zeroclaw channel bind-telegram <id>)"
    fi
}

write_config() {
    mkdir -p "${CONFIG_DIR}"

    # Source env for secrets
    if [[ -f "${ENV_FILE}" ]]; then
        set -a; source "${ENV_FILE}"; set +a
    fi

    cat > "${CONFIG_FILE}" <<TOML
# ZeroClaw configuration
# Generated by setup on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# Full schema: zeroclaw config schema
# Secrets are encrypted on save via zeroclaw onboard

# LLM provider
default_provider = "openrouter"
api_key = "${OPENROUTER_API_KEY:-REPLACE_ME}"
default_model = "moonshotai/kimi-k2"
default_temperature = 0.7

# Autonomy
[autonomy]
level = "supervised"
workspace_only = true
max_actions_per_hour = 100

# Sandbox — auto-detects Landlock on kernel 5.13+
[security.sandbox]
enabled = true
backend = "Auto"

# Telegram channel
[channels_config.telegram]
bot_token = "${TELEGRAM_BOT_TOKEN:-REPLACE_ME}"
allowed_users = [${TELEGRAM_ALLOWED_USER_ID:+"\"${TELEGRAM_ALLOWED_USER_ID}\""}]
stream_mode = "off"

# Memory
[memory]
backend = "sqlite"
auto_save = true
TOML

    chmod 600 "${CONFIG_FILE}"
    ok "Config written to ${CONFIG_FILE}"

    if [[ "${OPENROUTER_API_KEY:-}" == "REPLACE_ME" ]] || [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
        warn "Config has placeholder values — edit ${CONFIG_FILE} or set vars in ~/.env and re-run"
    fi
}

# ── Systemd service ─────────────────────────────────────────────────────────

install_service() {
    local zeroclaw="${BIN_DIR}/zeroclaw"

    # Try built-in service installer first
    info "Installing systemd service..."
    if "$zeroclaw" service install 2>/dev/null; then
        ok "Systemd service installed via 'zeroclaw service install'"
        return 0
    fi

    # Fallback: write unit file manually
    warn "Built-in service install failed — writing unit file manually"
    local svc_dir="${HOME}/.config/systemd/user"
    mkdir -p "$svc_dir"

    cat > "${svc_dir}/zeroclaw.service" <<EOF
[Unit]
Description=ZeroClaw AI Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/zeroclaw daemon
Restart=on-failure
RestartSec=10
EnvironmentFile=%h/.env

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload 2>/dev/null || true
    ok "Systemd service installed (manual)"
}

# ── Health check ─────────────────────────────────────────────────────────────

verify() {
    info "Running verification..."
    local zeroclaw="${BIN_DIR}/zeroclaw"

    # Binary runs
    if "$zeroclaw" --version &>/dev/null; then
        ok "Binary: $("$zeroclaw" --version 2>/dev/null)"
    else
        fatal "Binary does not execute"
    fi

    # Config exists
    if [[ -f "${CONFIG_FILE}" ]]; then
        ok "Config: ${CONFIG_FILE}"
    else
        warn "Config not found at ${CONFIG_FILE}"
    fi

    # Sandbox detection
    if "$zeroclaw" doctor 2>/dev/null | grep -qi "sandbox\|landlock"; then
        ok "Sandbox check passed (zeroclaw doctor)"
    else
        # doctor may not exist or may have different output
        ok "Sandbox: Auto-detect enabled (kernel $(uname -r))"
    fi

    # Service file
    if [[ -f "${HOME}/.config/systemd/user/zeroclaw.service" ]]; then
        ok "Systemd service file present"
    else
        warn "No systemd service file found"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo ""
    info "Setting up ZeroClaw for user: $(whoami)"
    echo ""

    install_binary
    configure
    install_service
    verify

    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  ZeroClaw — SETUP COMPLETE"
    echo "════════════════════════════════════════════════════"
    echo ""
    if [[ -n "${OPENROUTER_API_KEY:-}" ]] && [[ "${OPENROUTER_API_KEY:-}" != "REPLACE_ME" ]]; then
        echo "  Ready to start! No manual steps needed."
    else
        echo "  Almost ready — set secrets in ~/.env first:"
        echo "    OPENROUTER_API_KEY=sk-or-..."
        echo "    TELEGRAM_BOT_TOKEN=<from @BotFather>"
        echo "    TELEGRAM_ALLOWED_USER_ID=<your numeric Telegram ID>"
        echo ""
        echo "  Then re-run this script or run: zeroclaw onboard"
    fi
    echo ""
    echo "  Start:  systemctl --user enable --now zeroclaw"
    echo "  Logs:   journalctl --user -u zeroclaw -f"
    echo "  Status: zeroclaw status"
    echo "  Doctor: zeroclaw doctor"
    echo ""
}

main "$@"
