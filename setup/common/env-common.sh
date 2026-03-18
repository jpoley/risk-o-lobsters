#!/usr/bin/env bash
# env-common.sh — Per-user environment baseline for Claw platform users
#
# This file is SOURCED (not executed) from each user's .profile.
# Do NOT put secrets here — those go in ~/.env (chmod 600).

# ---------------------------------------------------------------------------
# Locale
# ---------------------------------------------------------------------------
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LANGUAGE="en_US:en"

# ---------------------------------------------------------------------------
# XDG Base Directories
# https://specifications.freedesktop.org/basedir-spec/latest/
# ---------------------------------------------------------------------------
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"
export XDG_CACHE_HOME="${HOME}/.cache"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------
# Add ~/.local/bin if not already in PATH
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac

# ---------------------------------------------------------------------------
# Common (non-secret) environment variables
# ---------------------------------------------------------------------------

# Claw evaluation environment marker
export CLAW_EVAL_ENV=1

# Default editor
export EDITOR="nano"
export VISUAL="nano"

# Disable telemetry for various tools
export DO_NOT_TRACK=1
export NEXT_TELEMETRY_DISABLED=1

# Rust (if installed system-wide, user may also have local toolchain)
if [ -f "${HOME}/.cargo/env" ]; then
    . "${HOME}/.cargo/env"
fi

# ---------------------------------------------------------------------------
# Source user secrets (LAST — so secrets can override anything above)
# ---------------------------------------------------------------------------
if [ -f "${HOME}/.env" ]; then
    # shellcheck disable=SC1091
    set -a
    . "${HOME}/.env"
    set +a
fi
