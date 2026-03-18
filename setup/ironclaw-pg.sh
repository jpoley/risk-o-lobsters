#!/usr/bin/env bash
set -euo pipefail

# ironclaw-pg.sh — Set up PostgreSQL + pgvector for IronClaw (idempotent)
#
# Creates a Docker container running pgvector/pgvector:pg15, waits for
# readiness, enables the vector extension, then points IronClaw's config
# at the database and restarts the service.
#
# Requirements: Docker running, izzy user exists with lingering enabled.
#
# Usage (as your normal user — will sudo where needed):
#   bash setup/ironclaw-pg.sh
#   bash setup/ironclaw-pg.sh --port 5434         # custom host port
#   bash setup/ironclaw-pg.sh --dry-run           # preview only
#
# Password: auto-generated (32-char alphanumeric) on first run,
# stored in izzy's ~/.ironclaw/.env as IRONCLAW_PG_PASSWORD.
# Re-runs reuse the existing password from the env file.

# ── Defaults ─────────────────────────────────────────────────────────────────

PG_CONTAINER="ironclaw-pg"
PG_IMAGE="pgvector/pgvector:pg15"
PG_DB="ironclaw"
PG_USER="ironclaw"
PG_HOST_PORT="5433"
IRONCLAW_USER="izzy"
DRY_RUN=false

# ── Helpers ──────────────────────────────────────────────────────────────────
# ALL diagnostic output goes to stderr so it never pollutes $() captures.

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*" >&2; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
fatal() { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*" >&2; exit 1; }

run() {
    if $DRY_RUN; then
        printf '\033[1;33m[DRY-RUN]\033[0m  %s\n' "$*" >&2
    else
        "$@"
    fi
}

# Run a command as the ironclaw user via login shell.
# .profile sets XDG_RUNTIME_DIR, PATH, sources ~/.env — no env hacks needed.
as_izzy() {
    sudo -iu "$IRONCLAW_USER" bash -c "$1"
}

# Check if a specific port is listening on 127.0.0.1.
# Uses ss sport filter for exact match (no substring false positives).
port_in_use() {
    local port="$1"
    ss -tln "sport = :${port}" 2>/dev/null | grep -q "127.0.0.1"
}

# ── Args ─────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)      PG_HOST_PORT="${2:?--port requires a value}"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--port PORT] [--dry-run]"
            echo "  Sets up PostgreSQL + pgvector for IronClaw (izzy)"
            echo "  Password is auto-generated and stored in izzy's ~/.ironclaw/.env"
            exit 0 ;;
        *) fatal "Unknown arg: $1" ;;
    esac
done

# ── Step 0: Ensure izzy has a .bashrc ────────────────────────────────────────
# .profile (created by create-user.sh) handles login shells. .bashrc handles
# interactive shells so `sudo -iu izzy` then running commands by hand works.

info "Ensuring ${IRONCLAW_USER} shell is configured..."

BASHRC_MARKER="# Claw platform bashrc"

if ! as_izzy "grep -qF '${BASHRC_MARKER}' \"\${HOME}/.bashrc\" 2>/dev/null"; then
    if $DRY_RUN; then
        printf '\033[1;33m[DRY-RUN]\033[0m  would append to ~%s/.bashrc\n' "$IRONCLAW_USER" >&2
    else
        sudo -iu "$IRONCLAW_USER" tee -a .bashrc >/dev/null << 'BASHRC_EOF'

# Claw platform bashrc
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PATH="${HOME}/bin:${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
[ -f "${HOME}/.env" ] && { set -a; . "${HOME}/.env"; set +a; }
BASHRC_EOF
    fi
fi
ok "${IRONCLAW_USER} .bashrc configured"

# ── Resolve or generate password ─────────────────────────────────────────────
# Reuse existing password from izzy's env if present, otherwise generate one.
# This ensures idempotency — re-runs don't rotate the password and break the
# running container.

generate_password() {
    # Read enough random bytes and extract 32 alphanumeric chars.
    # Avoid tr|head pipe — under pipefail, head closing early causes
    # tr to get SIGPIPE (exit 141), failing the whole pipeline.
    local pool
    pool="$(dd if=/dev/urandom bs=256 count=1 2>/dev/null | tr -dc 'A-Za-z0-9')"
    printf '%s' "${pool:0:32}"
}

resolve_password() {
    local existing=""
    existing="$(as_izzy \
        'f="${HOME}/.ironclaw/.env"; [ -f "$f" ] && grep "^IRONCLAW_PG_PASSWORD=" "$f" | cut -d= -f2-' \
        2>/dev/null)" || true

    if [[ -n "$existing" ]]; then
        info "Reusing existing PG password from ~${IRONCLAW_USER}/.ironclaw/.env"
        printf '%s' "$existing"
        return 0
    fi

    info "Generating new PG password (32-char alphanumeric)"
    generate_password
}

PG_PASSWORD="$(resolve_password)"

if [[ -z "$PG_PASSWORD" || ${#PG_PASSWORD} -lt 16 ]]; then
    fatal "Password generation failed — got ${#PG_PASSWORD} chars, need 32"
fi

PG_URL="postgresql://${PG_USER}:${PG_PASSWORD}@127.0.0.1:${PG_HOST_PORT}/${PG_DB}"

# ── Preflight ────────────────────────────────────────────────────────────────

info "Preflight checks..."

command -v docker &>/dev/null || fatal "Docker not installed"
docker info &>/dev/null 2>&1  || fatal "Docker not running (try: sudo systemctl start docker)"
id "$IRONCLAW_USER" &>/dev/null || fatal "User '${IRONCLAW_USER}' does not exist"

ok "Docker running, user ${IRONCLAW_USER} exists"

# ── Step 1: Container ───────────────────────────────────────────────────────

# Clean up broken container (exists but never started / failed to bind)
cleanup_broken_container() {
    local state
    state="$(docker inspect --format '{{.State.Status}}' "$PG_CONTAINER" 2>/dev/null)" || return 0
    case "$state" in
        created|dead)
            warn "Removing broken container '${PG_CONTAINER}' (state: ${state})"
            docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
            ;;
    esac
}

# Find an available port starting from the given port.
# Returns the port number on stdout — all diagnostics go to stderr via helpers.
find_available_port() {
    local port="$1"
    local max_port=$(( port + 10 ))
    while (( port <= max_port )); do
        if ! port_in_use "$port"; then
            echo "$port"
            return 0
        fi
        warn "Port ${port} in use — trying next"
        port=$(( port + 1 ))
    done
    fatal "No available port in range ${1}-${max_port}"
}

# Clean up any broken container first
cleanup_broken_container

if docker ps --format '{{.Names}}' | grep -qw "$PG_CONTAINER"; then
    ok "Container '${PG_CONTAINER}' already running"
elif docker ps -a --format '{{.Names}}' | grep -qw "$PG_CONTAINER"; then
    # Container exists and is stopped (not broken — that was cleaned above)
    info "Starting stopped container '${PG_CONTAINER}'..."
    if run docker start "$PG_CONTAINER"; then
        ok "Container started"
    else
        warn "Start failed — removing and recreating"
        docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
    fi
fi

# Create if it doesn't exist (or was just cleaned up)
if ! docker ps -a --format '{{.Names}}' | grep -qw "$PG_CONTAINER"; then
    # Ensure port is free before creating
    if port_in_use "$PG_HOST_PORT"; then
        original_port="$PG_HOST_PORT"
        PG_HOST_PORT="$(find_available_port "$((PG_HOST_PORT + 1))")"
        PG_URL="postgresql://${PG_USER}:${PG_PASSWORD}@127.0.0.1:${PG_HOST_PORT}/${PG_DB}"
        warn "Port ${original_port} in use by another process — using ${PG_HOST_PORT} instead"
    fi

    info "Creating container '${PG_CONTAINER}' (${PG_IMAGE}) on port ${PG_HOST_PORT}..."
    run docker run -d \
        --name "$PG_CONTAINER" \
        --restart unless-stopped \
        -e POSTGRES_DB="$PG_DB" \
        -e POSTGRES_USER="$PG_USER" \
        -e POSTGRES_PASSWORD="$PG_PASSWORD" \
        -p "127.0.0.1:${PG_HOST_PORT}:5432" \
        "$PG_IMAGE" >/dev/null
    ok "Container created (port ${PG_HOST_PORT}, restart: unless-stopped)"
fi

# ── Step 2: Wait for readiness ───────────────────────────────────────────────

if ! $DRY_RUN; then
    info "Waiting for PostgreSQL to accept connections..."
    retries=0
    until docker exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" &>/dev/null; do
        retries=$((retries + 1))
        if (( retries >= 30 )); then
            fatal "PostgreSQL did not become ready after 30s"
        fi
        sleep 1
    done
    ok "PostgreSQL ready (${retries}s)"
fi

# ── Step 3: Enable pgvector ──────────────────────────────────────────────────

info "Enabling pgvector extension..."
run docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
    -c "CREATE EXTENSION IF NOT EXISTS vector;"
ok "pgvector enabled"

# ── Step 4: Update IronClaw config ───────────────────────────────────────────

info "Updating IronClaw config to use PostgreSQL..."

if $DRY_RUN; then
    printf '\033[1;33m[DRY-RUN]\033[0m  would update ~%s/.ironclaw/.env\n' "$IRONCLAW_USER" >&2
else
    sudo -iu "$IRONCLAW_USER" bash -s "$PG_PASSWORD" "$PG_URL" << 'CONFIG_EOF'
PG_PASSWORD="$1"
PG_URL="$2"
ENV_FILE="${HOME}/.ironclaw/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Creating ~/.ironclaw/.env" >&2
    mkdir -p "${HOME}/.ironclaw"
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi

set_or_replace() {
    local key="$1" value="$2" file="$3"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

set_or_replace IRONCLAW_PG_PASSWORD "$PG_PASSWORD" "$ENV_FILE"
set_or_replace DATABASE_BACKEND postgres "$ENV_FILE"
set_or_replace DATABASE_URL "$PG_URL" "$ENV_FILE"

# Comment out LIBSQL_PATH if present (keep for rollback reference)
sed -i 's|^LIBSQL_PATH=|#LIBSQL_PATH=|' "$ENV_FILE"
CONFIG_EOF
fi
ok "IronClaw config updated (DATABASE_BACKEND=postgres)"

# ── Step 5: Restart IronClaw service ────────────────────────────────────────

info "Restarting IronClaw service..."
run as_izzy 'systemctl --user restart ironclaw' 2>/dev/null \
    || warn "Service restart failed — may need: sudo -iu ${IRONCLAW_USER} systemctl --user enable --now ironclaw"

if ! $DRY_RUN; then
    sleep 2
    if as_izzy 'systemctl --user is-active ironclaw' &>/dev/null; then
        ok "IronClaw service running"
    else
        warn "Service not active — check: sudo -iu ${IRONCLAW_USER} journalctl --user -u ironclaw --no-pager -n 20"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────

cat >&2 <<EOF

════════════════════════════════════════════════════
  IronClaw PostgreSQL — DONE
════════════════════════════════════════════════════

  Container:  ${PG_CONTAINER} (${PG_IMAGE})
  Port:       127.0.0.1:${PG_HOST_PORT}
  Database:   ${PG_DB}
  User:       ${PG_USER}
  pgvector:   enabled
  Restart:    unless-stopped (survives reboot)

  Connect:    psql 'postgresql://${PG_USER}:<see .env>@127.0.0.1:${PG_HOST_PORT}/${PG_DB}'
  Password:   stored in ~${IRONCLAW_USER}/.ironclaw/.env (IRONCLAW_PG_PASSWORD)
  Logs (pg):  docker logs ${PG_CONTAINER} --tail 20
  Logs (ic):  sudo -iu ${IRONCLAW_USER} journalctl --user -u ironclaw -f

EOF
