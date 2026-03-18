# Telegram Bot Setup — Claw Platform Evaluation

Step-by-step guide for creating Telegram bots for all 4 Claw platforms plus the carcinologistd monitoring daemon.

---

## Prerequisites

- A Telegram account (your personal account)
- Your Telegram user ID (see "Get Your Telegram User ID" below)

---

## Step 1: Get Your Telegram User ID

Your Telegram user ID is needed for the sender allowlist (so only you can talk to the bots).

1. Open Telegram
2. Search for `@userinfobot` and start a chat
3. Send `/start`
4. It replies with your user ID (a number like `123456789`)
5. Save this — you'll use it in every bot's config as the allowed sender

Alternative: search for `@raw_data_bot`, send `/start`, look for `"id":` in the response.

---

## Step 2: Create 5 Bots via @BotFather

Open a chat with [@BotFather](https://t.me/botfather) in Telegram.

### Bot 1: NanoClaw (nancy)

```
/newbot
```
- **Name:** `Nancy NanoClaw`
- **Username:** `NancyNanoClawBot`
- Save the token that BotFather returns.

### Bot 2: ZeroClaw (zlatan)

```
/newbot
```
- **Name:** `Zlatan ZeroClaw`
- **Username:** `ZlatanZeroClawBot`
- Save the token.

### Bot 3: OpenClaw (ollie)

```
/newbot
```
- **Name:** `Ollie OpenClaw`
- **Username:** `OllieOpenClawBot`
- Save the token.

### Bot 4: IronClaw (izzy)

```
/newbot
```
- **Name:** `Izzy IronClaw`
- **Username:** `IzzyIronClawBot`
- Save the token.

### Bot 5: Carcinologistd (monitoring)

```
/newbot
```
- **Name:** `Carcinologistd`
- **Username:** `CarcinologistdBot`
- Save the token.

---

## Step 3: Configure Each Bot

For each bot, still in the @BotFather chat:

### Disable group joining (privacy)

```
/setjoingroups
```
Select the bot, then choose `Disable`. Repeat for all 5 bots.

This prevents anyone from adding your bots to groups.

### Set bot descriptions

```
/setdescription
```
Select each bot and set an appropriate description:
- NancyNanoClawBot: `Auditable AI assistant (NanoClaw). Private — authorized users only.`
- ZlatanZeroClawBot: `Lightweight AI assistant (ZeroClaw). Private — authorized users only.`
- OllieOpenClawBot: `Full-featured AI assistant (OpenClaw). Private — authorized users only.`
- IzzyIronClawBot: `Security-first AI assistant (IronClaw). Private — authorized users only.`
- CarcinologistdBot: `Security monitoring daemon. Alerts only.`

---

## Step 4: Store Tokens

Each token goes into the corresponding user's `.env` file with `chmod 600`.

### nancy (NanoClaw)

```bash
# File: /home/nancy/.env
TELEGRAM_BOT_TOKEN=<NancyNanoClawBot token from BotFather>
```

### zlatan (ZeroClaw)

```bash
# File: /home/zlatan/.env
TELEGRAM_BOT_TOKEN=<ZlatanZeroClawBot token from BotFather>
```

### ollie (OpenClaw)

```bash
# File: /home/ollie/.env
TELEGRAM_BOT_TOKEN=<OllieOpenClawBot token from BotFather>
```

### izzy (IronClaw)

```bash
# File: /home/izzy/.env
TELEGRAM_BOT_TOKEN=<IzzyIronClawBot token from BotFather>
```

### carcinologistd (runs as a dedicated system user)

```bash
# File: wherever carcinologistd reads config
TELEGRAM_BOT_TOKEN=<CarcinologistdBot token from BotFather>
TELEGRAM_CHAT_ID=<your user ID from Step 1>
```

To write a token securely:

```bash
# As root, writing to nancy's env
sudo tee -a /home/nancy/.env <<< 'TELEGRAM_BOT_TOKEN=1234567890:ABCdefGHIjklMNOpqrsTUVwxyz'
sudo chmod 600 /home/nancy/.env
sudo chown nancy:nancy /home/nancy/.env
```

---

## Step 5: Sender Allowlist Configuration

Each platform has its own way to restrict who can send messages to the bot. In all cases, you need your Telegram user ID from Step 1.

### NanoClaw

NanoClaw uses a sender allowlist in its config. In the NanoClaw config file:

```json
{
  "telegram": {
    "allowed_sender_ids": [YOUR_TELEGRAM_USER_ID]
  }
}
```

### ZeroClaw

ZeroClaw uses channel authorization in its TOML config:

```toml
[telegram]
allowed_users = [YOUR_TELEGRAM_USER_ID]
```

### OpenClaw

OpenClaw uses DM pairing codes. After starting the bot:

1. Send a message to the bot
2. OpenClaw will show a pairing code in its logs
3. Approve the pairing via the admin interface

Alternatively, set sender allowlist in `settings.yaml`:

```yaml
telegram:
  allowedChatIds:
    - YOUR_TELEGRAM_USER_ID
```

### IronClaw

IronClaw uses sender allowlist in its config:

```toml
[telegram]
allowed_user_ids = [YOUR_TELEGRAM_USER_ID]
```

---

## Step 6: Verify Each Bot

After configuration, test each bot:

1. Open Telegram
2. Search for the bot username (e.g., `@NancyNanoClawBot`)
3. Send `/start`
4. Verify the bot responds (or check its logs on the server)

---

## Security Notes

- Tokens are equivalent to passwords. Store only in `.env` files with `chmod 600`.
- Never commit tokens to git.
- Rotate tokens immediately if compromised: use `/revoke` in @BotFather.
- The sender allowlist is your primary defense — deny-all by default.
- CarcinologistdBot should be one-way (alerts to you) — it does not need to accept commands.
- Consider using `/setcommands` in @BotFather to define available commands for each bot so users see a menu.

---

## Quick Reference

| Bot | Username | User | Token Location |
|-----|----------|------|----------------|
| Nancy NanoClaw | @NancyNanoClawBot | nancy | /home/nancy/.env |
| Zlatan ZeroClaw | @ZlatanZeroClawBot | zlatan | /home/zlatan/.env |
| Ollie OpenClaw | @OllieOpenClawBot | ollie | /home/ollie/.env |
| Izzy IronClaw | @IzzyIronClawBot | izzy | /home/izzy/.env |
| Carcinologistd | @CarcinologistdBot | (system) | carcinologistd config |
