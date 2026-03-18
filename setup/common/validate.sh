#!/usr/bin/env bash
set -euo pipefail

# validate.sh — Pre-flight checks for Claw platform setup
#
# CHECK ONLY. Does not install anything.
# If something is missing, it tells you what to install.
# Runs as any user (no root needed).

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}[OK]${NC} $1";    PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1";     FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1";  WARN=$((WARN + 1)); }
header() { echo ""; echo -e "${BOLD}=== $1 ===${NC}"; }

# ---------------------------------------------------------------------------
header "Docker"
# ---------------------------------------------------------------------------
if command -v docker &>/dev/null; then
    if docker info &>/dev/null; then
        DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        pass "Docker running (v${DOCKER_VERSION})"
    else
        fail "Docker installed but daemon not running — run: sudo systemctl start docker"
    fi
else
    fail "Docker not installed — run: sudo apt-get install -y docker.io && sudo systemctl enable --now docker"
fi

# ---------------------------------------------------------------------------
header "Kernel (Landlock for ZeroClaw)"
# ---------------------------------------------------------------------------
KERNEL_VERSION=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)

if (( KERNEL_MAJOR > 6 )) || (( KERNEL_MAJOR == 6 && KERNEL_MINOR >= 17 )); then
    pass "Kernel ${KERNEL_VERSION} (Landlock V5)"
elif (( KERNEL_MAJOR > 5 )) || (( KERNEL_MAJOR == 5 && KERNEL_MINOR >= 13 )); then
    pass "Kernel ${KERNEL_VERSION} (Landlock basic)"
else
    warn "Kernel ${KERNEL_VERSION} — no Landlock support (ZeroClaw will use fallback sandbox)"
fi

# ---------------------------------------------------------------------------
header "Disk Space"
# ---------------------------------------------------------------------------
AVAIL_KB=$(df --output=avail / | tail -1 | tr -d ' ')
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))

if (( AVAIL_GB >= 5 )); then
    pass "${AVAIL_GB}GB available"
else
    fail "Only ${AVAIL_GB}GB available — need at least 5GB"
fi

# ---------------------------------------------------------------------------
header "Node.js (needed for NanoClaw + OpenClaw)"
# ---------------------------------------------------------------------------
if command -v node &>/dev/null; then
    pass "Node.js $(node --version)"
else
    fail "Node.js not installed — run: sudo apt-get install -y nodejs (or use nodesource for v22+)"
fi

if command -v npm &>/dev/null; then
    pass "npm $(npm --version)"
else
    warn "npm not found"
fi

# ---------------------------------------------------------------------------
header "Extras"
# ---------------------------------------------------------------------------

if command -v git &>/dev/null; then
    pass "git $(git --version | awk '{print $3}')"
else
    fail "git not installed — run: sudo apt-get install -y git"
fi

if command -v curl &>/dev/null; then
    pass "curl available"
else
    fail "curl not installed — run: sudo apt-get install -y curl"
fi

if command -v systemctl &>/dev/null; then
    pass "systemd"
else
    fail "systemd not available"
fi

if command -v loginctl &>/dev/null; then
    pass "loginctl"
else
    warn "loginctl not available — user services may not survive logout"
fi

if command -v psql &>/dev/null; then
    pass "psql $(psql --version | awk '{print $3}')"
else
    warn "psql not installed (optional — IronClaw DB checks will use docker exec)"
fi

# ---------------------------------------------------------------------------
header "Summary"
# ---------------------------------------------------------------------------
echo ""
echo -e "  ${GREEN}Passed: ${PASS}${NC}  |  ${RED}Failed: ${FAIL}${NC}  |  ${YELLOW}Warnings: ${WARN}${NC}"
echo ""

if (( FAIL > 0 )); then
    echo -e "${RED}${BOLD}VALIDATION FAILED${NC} — fix the ${FAIL} issue(s) above, then re-run."
    exit 1
else
    echo -e "${GREEN}${BOLD}ALL CHECKS PASSED${NC}"
    exit 0
fi
