# Deckhand

Your servers, an agent and a terminal — in your pocket.

Deckhand is an iOS app for working on your own Linux servers from the iPhone:

- **Connect** a server over SSH in seconds (password, imported key, or a new Ed25519 key created on the phone). Host keys are pinned on first connect.
- **Agent** — bring your own model key (Anthropic, OpenAI, OpenRouter or any OpenAI-compatible endpoint). The agent loop runs on the phone; its tools (shell, read, write, edit, list, search) run on the server over SSH, with approvals for anything that changes the server.
- **Terminal** — a full xterm-compatible terminal over SSH.
- Coming next: Claude Code and Codex running on your server with your own subscription, rendered natively; tmux sessions; files.

No account, no backend. Keys stay in the iOS Keychain and requests go straight to your provider and your server.

## Layout

- `App/` — SwiftUI app (iOS 26+)
- `Packages/DeckhandKit` — `DeckhandCore` (providers, agent loop, server tools) and `DeckhandSSH` (SSH via Citadel)
- `project.yml` — XcodeGen spec

## Build

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Deckhand.xcodeproj -scheme Deckhand \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -skipPackagePluginValidation build
```

## Tests

```sh
cd Packages/DeckhandKit && swift test
# live SSH tests against a real server:
DECKHAND_TEST_HOST=example.com DECKHAND_TEST_PORT=22 DECKHAND_TEST_USER=me DECKHAND_TEST_KEY=~/.ssh/id_ed25519 swift test
```
