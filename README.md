<p align="center">
  <img src="claws.png" alt="A Risk of Lobsters" width="500">
</p>

# Claw Platform Evaluation Environment

Side-by-side evaluation of 4 personal AI agent platforms on a single Linux host, each running under its own isolated user account and talking to the operator via Telegram.

## Architecture: Native Install (not containers)

NanoClaw and IronClaw use Docker internally (per-chat containers, tool isolation). Running them in Docker containers would create Docker-in-Docker — fragile and insecure. ZeroClaw is a static binary that doesn't need one. OpenClaw doesn't benefit.

**Each platform is installed natively on its own Linux user, the way its authors intended.**

## Quick Start

```bash
cd jp/risk

# Set up one platform (prompts for name)
./setup.sh nanoclaw

# Set up one platform with a specific name
./setup.sh nanoclaw --as nora

# Set up all 4
./setup.sh

# Preview without doing anything
./setup.sh --dry-run nanoclaw --as nora

# Check status
./setup.sh --list
```

No `sudo` needed to start — fetch runs as you, then `sudo` is requested for the install step.

## Platforms

| Platform | Install Method | Interactive? | Docker Internally? | Sandbox |
|----------|---------------|-------------|-------------------|---------|
| ZeroClaw | Pre-built binary (3.4MB) | **No** — fully automatable | Optional | Landlock (kernel) |
| OpenClaw | `npm install -g openclaw` | `openclaw onboard` wizard | No | Application-layer |
| NanoClaw | Fork repo + Claude Code `/setup` | Claude Code interactive | **Yes** — container per chat | Docker + mount allowlist |
| IronClaw | Curl installer (pre-built) | Optional (`--quick` mode) | **Yes** — tool isolation | WASM (Wasmtime) |

Each platform runs as a dedicated Linux user. The username must start with the same letter as the platform.

**Name suggestions:**
- **n**: nancy, nora, niko, nina, noah, natasha, neil
- **z**: zlatan, zara, zoe, zach, zena, zeke, zuri
- **o**: ollie, oscar, olive, owen, ora, otto, opal
- **i**: izzy, ivan, iris, isla, igor, ida, ike

## What's Automated vs Manual

| Platform | Script Automates | Human Must Do |
|----------|-----------------|---------------|
| ZeroClaw | Everything (download, config, service) | Nothing |
| OpenClaw | npm install, version check, service | Run `openclaw onboard` |
| NanoClaw | Clone, npm install, build, Docker image, allowlist, service | Run `claude` → `/setup` → `/add-telegram` |
| IronClaw | Download binary, libsql config, service | Optional: `ironclaw onboard --quick` |

## Post-Setup

### 1. Telegram bots

Follow `setup/telegram-setup.md` to create bots via @BotFather.

### 2. API keys + tokens

Edit each user's `~/.env`:

| User | Required keys |
|------|--------------|
| n* (NanoClaw) | `CLAUDE_CODE_OAUTH_TOKEN` (subscription) or `ANTHROPIC_API_KEY`, `TELEGRAM_BOT_TOKEN` |
| z* (ZeroClaw) | `OPENROUTER_API_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USER_ID` |
| o* (OpenClaw) | `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `TELEGRAM_BOT_TOKEN` |
| i* (IronClaw) | `ANTHROPIC_API_KEY` or `OPENROUTER_API_KEY`, `TELEGRAM_BOT_TOKEN` |

### 3. Interactive onboarding (per platform)

```bash
# ZeroClaw — no onboard needed (fully automated from ~/.env)
sudo -u zlatan -i bash -c 'systemctl --user enable --now zeroclaw'

# OpenClaw
sudo -u ollie -i
openclaw onboard

# NanoClaw (uses Claude subscription, not API key)
sudo -u nancy -i
cd ~/nanoclaw && claude
/setup
/add-telegram

# IronClaw (optional — env vars are sufficient)
sudo -u izzy -i
ironclaw onboard --quick
```

### 4. Start services

```bash
sudo -u <username> -i bash -c 'systemctl --user enable --now <platform>'
```

## Verification

Per platform, after setup + manual onboard:

1. Send a Telegram message to the bot → verify response
2. Check sandbox is active (ZeroClaw: Landlock, IronClaw: WASM, NanoClaw: Docker)
3. Verify `openclaw --version` >= 2026.2.2
4. Verify ZeroClaw source URL is `zeroclaw-labs/zeroclaw`
5. Verify cross-user file read fails (`chmod 700` homes)
6. `zeroclaw doctor` / `ironclaw doctor` / `ironclaw status`

## Monitoring: carcinologistd

A Go daemon that watches all 4 platforms and alerts via Telegram.

**Build and install:**
```bash
cd carcinologistd
go build -o carcinologistd .
sudo cp carcinologistd /usr/local/bin/
sudo cp carcinologistd.service /etc/systemd/system/
sudo mkdir -p /etc/carcinologistd
sudo cp config.toml /etc/carcinologistd/
# Edit config, then:
sudo systemctl enable --now carcinologistd
```

## File Structure

```
jp/risk/
├── setup.sh                         ← Run from here (no sudo needed)
├── README.md
├── .repos/                           ← Downloaded binaries + cloned repos
├── .platform-users                   ← Tracks username↔platform mapping
├── setup/
│   ├── setup.sh                      ← Main orchestrator (fetch + install)
│   ├── fetch.sh                      ← Download binaries, clone repos (no root)
│   ├── install.sh                    ← Create users, run platform scripts (sudo)
│   ├── telegram-setup.md             ← @BotFather walkthrough
│   ├── common/
│   │   ├── validate.sh               ← Docker running? Node.js? Disk space?
│   │   ├── create-user.sh            ← Linux user creation + isolation
│   │   └── env-common.sh             ← Shared env baseline for user profiles
│   └── platforms/
│       ├── zeroclaw.sh               ← Download binary, configure, DONE
│       ├── openclaw.sh               ← npm install, version check, print onboard steps
│       ├── nanoclaw.sh               ← Clone, build, Docker image, print Claude steps
│       └── ironclaw.sh               ← Download binary, libsql config, optional onboard
├── carcinologistd/                   ← Go monitoring daemon (keep as-is)
├── goal.md                           ← Original goals
└── .logs/decisions/                  ← Architectural decision records
```

## Security

- Separate Linux users with `chmod 700` homes
- No sudo for any platform user
- Docker group only for platforms that need it (NanoClaw, IronClaw)
- ZeroClaw: supply-chain URL verification, Landlock sandbox, secret encryption (ChaCha20Poly1305)
- OpenClaw: version >= 2026.2.2 enforced (CVE-2026-25253 patch)
- IronClaw: WASM sandbox (Wasmtime), credential injection, endpoint allowlisting, leak detection
- NanoClaw: mount allowlist, credential proxy (containers never see real API keys)
- Telegram sender allowlist on all 4 (operator's user ID only)

