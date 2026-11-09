# How we verify user stories

Every user story on the [roadmap board](https://github.com/users/Riyad-Eita/projects/3) links to one or more of the
methods below in its **Verification** section, together with the concrete checks for that story. A story is only
moved to *Done* when every listed check has passed and the evidence is linked in the pull request
(test names, screenshots or a short recording).

| Id | Method | Evidence in the PR |
|----|--------|--------------------|
| [V1](#v1-unit-tests) | Unit tests | Test names, `swift test` green |
| [V2](#v2-live-server-tests) | Live server tests | Test names, run against a real Linux server |
| [V3](#v3-ui-tests) | UI tests | XCUITest names, run in the simulator |
| [V4](#v4-simulator-review) | Simulator review | Screenshots (light and dark) or a screen recording |
| [V5](#v5-device-test) | Device test | Notes or recording from a real iPhone (incl. an older model) |
| [V6](#v6-store-and-release-check) | Store and release check | App Store Connect / TestFlight state |
| [V7](#v7-security-review) | Security review | Checklist below, filled in the PR |

## V1 Unit tests

Logic lives in `Packages/DeckhandKit` so it can be tested on macOS without a device:
parsers, providers, the agent loop, command builders, safety checks.

```sh
cd Packages/DeckhandKit && swift test
```

Rules: no network, no real server. Recorded fixtures go to `Tests/*/Fixtures`.

## V2 Live server tests

Integration tests that talk to a real Linux server over SSH (and, where relevant, to the real Codex / Claude Code CLIs
or public MCP servers). They are skipped unless the environment provides a server:

```sh
DECKHAND_TEST_HOST=example.com DECKHAND_TEST_PORT=22 DECKHAND_TEST_USER=me \
DECKHAND_TEST_KEY=~/.ssh/id_ed25519 swift test
# opt-in extras
DECKHAND_TEST_CLI=1        # runs a real Codex turn (uses the account's quota)
DECKHAND_TEST_HTTP_MCP=1   # talks to a public HTTP MCP server
```

Tests must clean up everything they create on the server.

## V3 UI tests

XCUITests for flows that must never break: adding a server, starting a task, approving a tool call, sending a
command in the terminal. Run with:

```sh
xcodebuild test -project Deckhand.xcodeproj -scheme Deckhand \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -skipPackagePluginValidation
```

## V4 Simulator review

Visual and interaction check in the simulator against a real server, using the debug launch hooks
(`DECKHAND_SEED_*`, see `App/Sources/Services/DebugSeed.swift`) so screens can be reached without tapping.
Attach screenshots in light and dark mode, at the largest Dynamic Type size when text layout matters.
Screenshots must not show real hostnames, users or folders — use demo data.

## V5 Device test

On a real iPhone, including an older one (iPhone 13 Pro): performance, memory, background behaviour, microphone,
Face ID, notifications, Live Activities, network changes (Wi-Fi ↔ cellular, airplane mode).

## V6 Store and release check

For release work: TestFlight build processed and installable, App Store Connect metadata complete, privacy label
correct, review notes present, submission state.

## V7 Security review

For anything touching keys, tokens, servers or permissions:

- [ ] Secrets only in the Keychain or in `0600` files on the user's own server; never logged, never in screenshots
- [ ] Nothing leaves the device except to the user's server and the provider the user chose
- [ ] Destructive actions need explicit confirmation
- [ ] Failure modes tested (wrong key, changed host key, revoked token, dropped connection)
