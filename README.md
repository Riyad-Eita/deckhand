<p align="center">
  <img src="docs/images/icon.png" width="96" height="96" alt="Deckhand icon">
</p>

<h1 align="center">Deckhand</h1>

<p align="center">
  <b>Your servers, a real terminal and AI coding agents — in your pocket.</b><br>
  SSH · Codex · Claude Code · your own model key · MCP · on-device voice
</p>

<p align="center">
  <a href="https://github.com/users/Riyad-Eita/projects/3">Roadmap</a> ·
  <a href="docs/verification.md">How we verify</a> ·
  <a href="docs/privacy.md">Privacy</a> ·
  <a href="https://github.com/Riyad-Eita/deckhand/issues">Feedback</a>
</p>

<p align="center">
  <img src="docs/images/agent.jpg" width="16%" alt="Agents on your server">
  <img src="docs/images/engines.jpg" width="16%" alt="Claude Code, Codex or your key">
  <img src="docs/images/terminal.jpg" width="16%" alt="A real terminal">
  <img src="docs/images/subscription.jpg" width="16%" alt="Your subscription on your server">
  <img src="docs/images/connections.jpg" width="16%" alt="Connect everything with MCP">
  <img src="docs/images/servers.jpg" width="16%" alt="Every server one tap away">
</p>

> **Beta.** Deckhand is brand new and moving fast. Many more features land with every release —
> see the [roadmap board](https://github.com/users/Riyad-Eita/projects/3) and tell us what you need.

## Why

Fixing a server, checking a deploy or letting an agent work on your code usually means: find a laptop, open a
terminal, SSH in, start Claude Code or Codex, keep the session alive. Deckhand does all of that from your iPhone —
and grows into the one app for the tools people otherwise pay for separately (SSH client, server panel, monitoring,
Git client, database GUI, AI subscriptions).

## What works today

- **SSH that just works** — password, imported key, or an Ed25519 key created on the phone. Host keys are pinned on
  first connect. Connections quietly come back after dead spots.
- **A real terminal** — xterm-compatible, with Esc/Ctrl/arrow keys. Sessions live in `tmux` or `screen`, so you can
  reconnect and continue where you left off.
- **Agents on your server**
  - *Your own key*: Claude, OpenAI, OpenRouter or any OpenAI-compatible endpoint. The agent loop runs on the phone, its
    tools (shell, read, write, edit, search) run on your server over SSH. It asks before changing things, and always
    before destructive commands (`rm -rf`, `DROP DATABASE`, force pushes, reboots …).
  - *Your subscription*: run **Codex** or **Claude Code** on your server and follow every step natively in the app.
    Install, update and sign in to them from the app — no root needed.
  - Pick the project folder per task.
- **Connections (MCP)** — pick from a catalog (GitHub, Hugging Face, Stripe, Playwright, docs servers …) or add any
  MCP server. The own-key agent uses them directly; one tap syncs them into Codex and Claude Code on your server.
- **Run the server** — dashboard, files, processes, services, logs, Docker, Git, package updates, disk usage, and
  web apps from `localhost` opened through an SSH tunnel.
- **When something breaks** — uptime checks run on the server and push when a site goes down. The incident view
  collects the facts (failed services, recent errors, what changed since it last worked) and an agent finds the cause
  read-only; one tap applies the fix, and a fix that worked once can run on its own next time.
- **Know your server** — a change history of packages, services, ports, containers, cron jobs and `/etc`; a
  read-only X-ray of an unknown server (sites, request flow, databases, backups, risks) that the agents remember.
- **Data** — encrypted restic backups to S3/B2/R2, SFTP or a folder; nightly database dumps with a test restore; a
  database browser for Postgres, MySQL, SQLite and Redis — all over SSH, no database port open.
- **Ship** — deploy from Git with a health check that rolls back by itself, auto-deploy on push without a webhook,
  one-tap rollbacks, and domains with HTTPS through Caddy.
- **Security** — one-tap hardening, SSH port moves that can't lock you out, firewall and fail2ban, login alerts, a
  security score, house rules every agent must obey, approvals from the lock screen, a panic button and tripwires.
  Every change is backed up and can be undone.
- **Voice** — optional on-device speech-to-text with OpenAI's Whisper (large-v3). Nothing leaves the phone.
- **Private by design** — no account, no tracking, no Deckhand backend. Secrets live in the iOS Keychain.

## What's next

Agents that plan first, read screenshots and ask your database in plain language; creating cloud servers; SSH only
through Tailscale; the Mac as a build server; App Store Connect — every item is a user story with acceptance criteria
and a linked verification method on the [board](https://github.com/users/Riyad-Eita/projects/3), grouped into
[milestones](https://github.com/Riyad-Eita/deckhand/milestones).

## Build it yourself

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Deckhand.xcodeproj -scheme Deckhand \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -skipPackagePluginValidation build
```

Tests (see [docs/verification.md](docs/verification.md)):

```sh
cd Packages/DeckhandKit && swift test                      # unit tests
DECKHAND_TEST_HOST=example.com DECKHAND_TEST_PORT=22 \
DECKHAND_TEST_USER=me DECKHAND_TEST_KEY=~/.ssh/id_ed25519 swift test   # live server tests
```

## Layout

| Path | What |
|------|------|
| `App/` | SwiftUI app (iOS 26+) |
| `Packages/DeckhandKit/Sources/DeckhandCore` | Providers, agent loop, server tools, server CLIs, MCP, safety checks |
| `Packages/DeckhandKit/Sources/DeckhandSSH` | SSH (Citadel / SwiftNIO SSH), terminal sessions, line channels |
| `UITests/` | End-to-end UI tests against a real server |
| `docs/` | Verification methods, privacy policy |

If Deckhand is useful to you, a ⭐ helps a lot.
