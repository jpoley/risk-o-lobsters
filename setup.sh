#!/usr/bin/env bash
# Wrapper — run setup from the root dir (no sudo needed to start)
exec "$(dirname "${BASH_SOURCE[0]}")/setup/setup.sh" "$@"
