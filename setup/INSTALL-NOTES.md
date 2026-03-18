# Verified Install Notes

Research findings from reading actual source code of each platform.
These notes drove the script rewrites.

## ZeroClaw

**Source:** `.repos/zeroclaw/`

### Binary
- Official install.sh: `--prebuilt-only --skip-onboard` flags verified
- Installs to `~/.cargo/bin/zeroclaw`
- Tarball format: `zeroclaw-x86_64-unknown-linux-gnu.tar.gz`
- Version 0.3.3 (as of repo clone)

### CLI
- `zeroclaw onboard --api-key <key> --provider openrouter` — verified in clap args
- `zeroclaw service install` — built-in systemd installer
- `zeroclaw daemon` — the actual long-running mode
- `zeroclaw doctor` — diagnostics
- `zeroclaw status` — health check
- `zeroclaw channel add telegram` — channel management

### Config
- Location: `~/.zeroclaw/config.toml` (NOT `~/.zeroclaw/zeroclaw.toml`)
- Top-level fields: `api_key`, `default_provider`, `default_model`, `default_temperature`
- Telegram: `[channels_config.telegram]` (NOT `[channels.telegram]`)
  - `allowed_users` = list of strings (NOT `allowed_user_ids`)
- Sandbox: `[security.sandbox]` with `backend = "Auto"` (auto-detects Landlock)
- Secrets encrypted via ChaCha20Poly1305 on save

### Sandbox
- Landlock: feature-gated `sandbox-landlock`, auto-detected on Linux kernel 5.13+
- Fallback chain: Landlock > Firejail > Bubblewrap > Docker > Noop
- Config: `backend = "Auto"` is safest

---

## IronClaw

**Source:** `.repos/ironclaw/`

### Binary
- Shell installer: `curl ... ironclaw-installer.sh | sh`
- Installs to `~/.cargo/bin/ironclaw`
- Also available via homebrew

### CLI
- `ironclaw onboard --quick` — auto-defaults everything except LLM provider
- `ironclaw onboard --skip-auth` — skip NEAR AI OAuth
- `ironclaw --no-onboard` — skip first-run check entirely
- `ironclaw service install` — built-in systemd installer
- `ironclaw run` — the actual long-running mode
- `ironclaw doctor` — diagnostics
- `ironclaw status` — health check

### Config (TWO layers)
1. `~/.ironclaw/.env` — bootstrap vars loaded BEFORE database
   - `DATABASE_BACKEND=libsql` (zero-config!) or `postgres`
   - `LIBSQL_PATH=~/.ironclaw/ironclaw.db`
   - `LLM_BACKEND=anthropic` / `openai_compatible` / `ollama` / etc.
   - `ONBOARD_COMPLETED=true` — skip auto-trigger
2. Database `settings` table — everything else
3. Optional: `~/.ironclaw/config.toml` — overrides DB settings

### Database
- **libsql is the default** — embedded SQLite-compatible, zero configuration
- PostgreSQL 15+ with pgvector is optional for production scale
- Quick mode uses libsql automatically

### LLM (no NEAR AI required!)
- 21+ providers in providers.json
- Set `LLM_BACKEND=anthropic` + `ANTHROPIC_API_KEY` to skip NEAR AI entirely
- Or `LLM_BACKEND=openai_compatible` + `LLM_BASE_URL` for OpenRouter

### Telegram
- WASM channel (NOT built into binary)
- Needs: build from source or download pre-built wasm
- DM pairing: `ironclaw pairing approve telegram <code>`
- Config in `~/.ironclaw/channels/telegram.capabilities.json`

### Sandbox
- WASM: Wasmtime embedded, capability-based, fuel metering
- Docker: separate, for heavier workloads
- Both have leak detection + endpoint allowlisting

---

## NanoClaw

**Source:** `.repos/nanoclaw/`

### Install
- Clone repo, `npm install` (6 deps, better-sqlite3 needs gcc/make)
- `npm run build` → `node dist/index.js` (preferred over tsx)
- Docker image: `cd container && bash build.sh` → `nanoclaw-agent:latest`

### Auth
- **Subscription**: `CLAUDE_CODE_OAUTH_TOKEN` in `.env` (from `claude setup-token`)
- **API key**: `ANTHROPIC_API_KEY` in `.env`
- Credential proxy auto-detects which mode

### /setup skill
- Claude Code skill (instructional markdown, not code)
- Runs `bash setup.sh` for bootstrap (checks Node.js, npm ci, verifies better-sqlite3)
- Steps: environment → container runtime → auth → channels → mounts → service → verify

### /add-telegram skill
- Merges from separate repo: `qwibitai/nanoclaw-telegram`
- Adds: `src/channels/telegram.ts`, grammy dep, TELEGRAM_BOT_TOKEN
- Registration: `npx tsx setup/index.ts --step register -- --jid "tg:<chat-id>" --channel telegram`

### Credential Proxy
- Port 3001 (CREDENTIAL_PROXY_PORT env var)
- API key mode: replaces `x-api-key` header
- OAuth mode: replaces `Authorization: Bearer` header
- Linux bind: docker0 bridge IP (172.17.0.1) or 0.0.0.0

### Mount Allowlist
- Location: `~/.config/nanoclaw/mount-allowlist.json`
- Format: `{ "allowedRoots": [...], "blockedPatterns": [...], "nonMainReadOnly": true }`
- Stored OUTSIDE project root (containers can't tamper)

### Systemd
- Use `node dist/index.js` (compiled) not `npx tsx` (runtime dep)
- WorkingDirectory must be the repo root
- Needs PATH with node binary dir

---

## OpenClaw

### Install
- `npm install -g openclaw`
- Version check: `openclaw --version` must be >= 2026.2.2

### Onboard
- Interactive wizard, cannot be scripted
- Generates 53+ config files
- DM pairing code for Telegram

### Systemd
- Use absolute path to openclaw binary (survives nvm/fnm version changes)
- PATH must include node bin dir
- Prefer fnm over nvm (no unbound variable issues)
