import Foundation

/// A real browser on the server for the agent: Playwright's MCP server with a headless Chromium, installed into the
/// user's home (`~/.deckhand/browser`, Node.js in `~/.local/node` when the server has none). It is a stdio process
/// the app starts through the SSH connection — nothing listens on the network. Pages, clicks, forms and screenshots
/// come back as tool results; the screenshots show up in the chat.
public enum BrowserSetup {
    public static let directory = "~/.deckhand/browser"
    /// The headless browser Playwright downloads (smaller than full Chromium, no UI parts).
    static let browser = "chromium-headless-shell"

    public struct Status: Sendable, Hashable {
        /// `v22.11.0` or nil.
        public var node: String?
        /// The MCP server package is in place.
        public var installed = false
        /// Playwright's browser is downloaded.
        public var browserReady = false
        /// The browser starts and renders (checked with a tiny page).
        public var works = false
        /// Shared libraries the browser is missing (needs the system's package manager, so root).
        public var missingLibraries: [String] = []
        public var arch = ""
        public var diskFreeMB = 0
        public var version: String?
    }

    static let env = #"export PATH="$HOME/.local/bin:$HOME/.local/node/bin:$PATH"; export PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/ms-playwright""#

    public static let statusCommand = """
    \(env); D=\(directory)
    echo "@@arch $(uname -m)"
    echo "@@disk $(df -Pm "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
    command -v node >/dev/null 2>&1 && echo "@@node $(node --version 2>/dev/null)"
    [ -f "$D/node_modules/@playwright/mcp/cli.js" ] && echo "@@installed $(node -p 'require("'"$D"'/node_modules/@playwright/mcp/package.json").version' 2>/dev/null)"
    ls -d "$HOME/.cache/ms-playwright"/chromium*headless*shell-* >/dev/null 2>&1 && echo '@@browser'
    if [ -f "$D/check.js" ] && command -v node >/dev/null 2>&1; then
      out=$(cd "$D" && timeout 60 node check.js 2>&1); code=$?
      if [ "$code" = 0 ]; then echo '@@works'; else printf '%s\\n' "$out" | grep -oE '[a-zA-Z0-9_.+-]+\\.so(\\.[0-9]+)*' | sort -u | sed 's/^/@@missing /'; fi
    fi
    true
    """

    public static func parse(_ output: String) -> Status {
        var s = Status()
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("@@arch ") { s.arch = String(line.dropFirst(7)) }
            else if line.hasPrefix("@@disk ") { s.diskFreeMB = Int(line.dropFirst(7)) ?? 0 }
            else if line.hasPrefix("@@node ") { s.node = String(line.dropFirst(7)) }
            else if line.hasPrefix("@@installed") { s.installed = true; s.version = line.dropFirst(11).trimmingCharacters(in: .whitespaces).nilIfBlank }
            else if line == "@@browser" { s.browserReady = true }
            else if line == "@@works" { s.works = true }
            else if line.hasPrefix("@@missing ") { s.missingLibraries.append(String(line.dropFirst(10))) }
        }
        return s
    }

    /// Opens a tiny page and renders it: exit 0 when the browser runs on this server.
    static let checkScript = """
    const {chromium} = require('playwright');
    (async () => {
      const b = await chromium.launch({headless: true, args: ['--no-sandbox']});
      const p = await b.newPage(); await p.setContent('<h1>ok</h1>');
      const png = await p.screenshot(); await b.close();
      if (png.length < 100) throw new Error('empty screenshot');
      console.log('ok ' + png.length);
    })().catch(e => { console.error(String(e && e.message || e)); process.exit(1); });
    """

    /// Takes a screenshot of `url` (1280×800, full page off) and prints it as `@@png <base64>` — "Try it" in the app.
    public static func screenshotCommand(url: String, width: Int = 1280, height: Int = 800) -> String {
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme ?? "") else { return "echo '@@failed bad url'" }
        let js = """
        const {chromium} = require('playwright');
        (async () => {
          const b = await chromium.launch({headless: true, args: ['--no-sandbox']});
          const p = await b.newPage({viewport: {width: \(width), height: \(height)}});
          await p.goto(process.argv[1], {waitUntil: 'load', timeout: 30000});
          const png = await p.screenshot({type: 'jpeg', quality: 80}); await b.close();
          console.log('@@png ' + png.toString('base64'));
        })().catch(e => { console.log('@@failed ' + String(e && e.message || e)); process.exit(0); });
        """
        return "\(env); cd \(directory) && timeout 90 node -e \(ShellQuote.quote(js)) \(ShellQuote.quote(url)) 2>/dev/null"
    }

    /// The picture, or why there is none.
    public static func parseScreenshot(_ output: String) -> (image: Data?, error: String?) {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("@@") }) else { return (nil, "No answer from the browser.") }
        if line.hasPrefix("@@png "), let d = Data(base64Encoded: String(line.dropFirst(6))) { return (d, nil) }
        return (nil, String(line.dropFirst(9)))
    }

    /// Installs everything into the user's home. Prints `@@step …` lines, `@@needsdeps` when the browser lacks system
    /// libraries (then `depsScript` as root), and `@@ok` at the end.
    public static let installScript = """
    set -e
    \(env); D=\(directory); mkdir -p "$D" "$HOME/.local/bin"; chmod 700 "$HOME/.deckhand" 2>/dev/null || true
    case "$(uname -m)" in x86_64|amd64) A=x64;; aarch64|arm64) A=arm64;; *) echo "Unsupported CPU $(uname -m)"; exit 1;; esac
    if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 20 ]; then
      echo '@@step Node.js'
      V=$(curl -fsSL https://nodejs.org/dist/latest-v22.x/ | grep -oE "node-v22\\.[0-9.]+-linux-$A\\.tar\\.xz" | head -n 1)
      [ -n "$V" ] || { echo "Couldn't find a Node.js download for linux-$A."; exit 1; }
      curl -fsSL "https://nodejs.org/dist/latest-v22.x/$V" -o /tmp/deckhand-node.tar.xz
      rm -rf "$HOME/.local/node"; mkdir -p "$HOME/.local/node"
      tar -xJf /tmp/deckhand-node.tar.xz -C "$HOME/.local/node" --strip-components=1; rm -f /tmp/deckhand-node.tar.xz
      for b in node npm npx; do ln -sf "$HOME/.local/node/bin/$b" "$HOME/.local/bin/$b"; done
    fi
    echo "@@step Playwright $(node --version)"
    cd "$D"
    [ -f package.json ] || printf '{"name":"deckhand-browser","private":true}\\n' > package.json
    npm install --no-audit --no-fund --loglevel=error @playwright/mcp@latest playwright@latest >/dev/null 2>&1 || { npm install --no-audit --no-fund --loglevel=error @playwright/mcp@latest playwright@latest 2>&1 | tail -n 5; exit 1; }
    echo '@@step browser'
    ./node_modules/.bin/playwright install \(browser) >/dev/null 2>&1 || { ./node_modules/.bin/playwright install \(browser) 2>&1 | tail -n 5; exit 1; }
    printf '%s\\n' \(ShellQuote.quote(checkScript)) > check.js
    echo '@@step check'
    if ! out=$(timeout 60 node check.js 2>&1); then
      printf '%s\\n' "$out" | grep -oE '[a-zA-Z0-9_.+-]+\\.so(\\.[0-9]+)*' | sort -u | sed 's/^/@@missing /'
      echo '@@needsdeps'; exit 0
    fi
    echo '@@ok'
    """

    /// Run as root: the shared libraries the browser needs, from the system's package manager (Playwright knows them).
    public static let depsScript = """
    set -e
    \(env); D=\(directory)
    echo '@@step libraries'
    cd "$D" && ./node_modules/.bin/playwright install-deps \(browser) >/dev/null 2>&1 || { ./node_modules/.bin/playwright install-deps \(browser) 2>&1 | tail -n 5; exit 1; }
    echo '@@ok'
    """

    /// The MCP server as the app starts it over SSH (stdio, nothing on the network). `--isolated`: every chat starts
    /// with a fresh browser profile; `--no-sandbox` because containers often lack user namespaces.
    public static let mcpCommand = "\(env); cd \(directory) && exec node node_modules/@playwright/mcp/cli.js --headless --isolated --no-sandbox"

    /// Everything the setup put there (Node.js in ~/.local/node stays when other things use it).
    public static let removeCommand = "rm -rf \(directory) \"$HOME/.cache/ms-playwright\"; echo '@@ok'"
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
