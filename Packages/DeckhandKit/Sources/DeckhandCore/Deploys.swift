import Foundation

/// PaaS-style deploys from Git to the user's own server, without root and without an open port: releases in
/// `~/.deckhand/apps/<name>/releases`, a `current` link, a health check that rolls back by itself, the last N releases
/// for one-tap rollbacks, a log per deploy, and optional auto-deploy when the branch moves (polled by cron).
public enum Deploys {
    static let root = "$HOME/.deckhand/apps"

    public struct App: Sendable, Hashable, Identifiable {
        public var name: String
        public var repo: String
        public var branch: String = "main"
        public var build: String = ""
        public var start: String = ""
        public var health: String = ""
        public var keep: Int = 5
        public var autoDeploy = false
        public var id: String { name }
        public init(name: String, repo: String, branch: String = "main", build: String = "", start: String = "", health: String = "", keep: Int = 5, autoDeploy: Bool = false) {
            self.name = name; self.repo = repo; self.branch = branch; self.build = build; self.start = start; self.health = health
            self.keep = keep; self.autoDeploy = autoDeploy
        }
        public static func isValidName(_ n: String) -> Bool { n.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil }
    }

    /// Ready-made build and start commands.
    public struct Preset: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var build: String
        public var start: String
        public static let all: [Preset] = [
            Preset(name: "Node.js", build: "npm ci && npm run build --if-present", start: "npm start"),
            Preset(name: "Python", build: "python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt", start: ".venv/bin/python app.py"),
            Preset(name: "Docker Compose", build: "", start: "docker compose up --build"),
            Preset(name: "Static site", build: "", start: ""),
        ]
    }

    static func q(_ s: String) -> String { ShellQuote.quote(s) }

    /// The deploy script (generic; reads app.env). Usage: `deploy.sh [--if-changed]`.
    static let deployScript = #"""
    #!/bin/bash
    # Deckhand deploy. Managed by the Deckhand app.
    set -u
    A="$(cd "$(dirname "$0")" && pwd)"; . "$A/app.env"
    mkdir -p "$A/logs" "$A/releases"
    exec 9>"$A/.lock"; command -v flock >/dev/null 2>&1 && { flock -n 9 || exit 0; }
    if [ ! -d "$A/repo/.git" ]; then git clone -q --branch "$BRANCH" "$REPO" "$A/repo" 2>"$A/.clone-error" || { echo "$(date +%s) - failed clone: $(tail -n 1 "$A/.clone-error")" >> "$A/deploys.log"; exit 1; }; fi
    if [ "${1:-}" = --if-changed ]; then
      remote=$(git -C "$A/repo" ls-remote origin "refs/heads/$BRANCH" 2>/dev/null | cut -c1-40)
      live=$(cat "$A/current/.deckhand-sha" 2>/dev/null)
      [ -n "$remote" ] && [ "$remote" != "$live" ] || exit 0
    fi
    ts=$(date -u +%Y%m%d-%H%M%S); L="$A/logs/$ts.log"
    stop() { [ -f "$A/app.pid" ] && kill -TERM -- "-$(cat "$A/app.pid")" 2>/dev/null; sleep 1; kill -KILL -- "-$(cat "$A/app.pid" 2>/dev/null)" 2>/dev/null; rm -f "$A/app.pid"; }
    # The subshell execs into the app (no shell left waiting, the lock not inherited).
    start() { [ -n "$START" ] || return 0; ( cd "$A/current" && exec setsid nohup sh -c "$START" >> "$A/app.log" 2>&1 < /dev/null 9>&- ) & echo $! > "$A/app.pid"; }
    switch() { ln -sfn "$1" "$A/current.tmp" && mv -Tf "$A/current.tmp" "$A/current"; }
    healthy() { [ -n "$HEALTH" ] || return 0; for i in $(seq 1 30); do curl -fsS -m 3 -o /dev/null "$HEALTH" 2>/dev/null && return 0; sleep 1; done; return 1; }
    (
      echo "== fetch $BRANCH from $REPO"
      git -C "$A/repo" fetch -q origin "$BRANCH" && git -C "$A/repo" reset -q --hard FETCH_HEAD || { echo '@@failed fetch'; exit 1; }
      sha=$(git -C "$A/repo" rev-parse HEAD); short=${sha:0:7}; msg=$(git -C "$A/repo" log -1 --format=%s | tr '\n\t' '  ')
      echo "== commit $short $msg"
      R="$A/releases/$ts-$short"; mkdir -p "$R" && git -C "$A/repo" archive HEAD | tar -x -C "$R" && echo "$sha" > "$R/.deckhand-sha"
      if [ -n "$BUILD" ]; then echo "== build: $BUILD"; (cd "$R" && sh -c "$BUILD") || { echo '@@failed build'; rm -rf "$R"; exit 1; }; fi
      prev=$(readlink "$A/current" 2>/dev/null)
      echo "== start"; stop; switch "$R"; start
      if ! healthy; then
        echo "@@failed health check $HEALTH — rolling back"
        stop; if [ -n "$prev" ] && [ -d "$prev" ]; then switch "$prev"; start; healthy && echo '== previous release is live again'; fi
        exit 2
      fi
      echo '@@live'
      ls -1d "$A"/releases/*/ 2>/dev/null | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do [ "${old%/}" = "$(readlink "$A/current")" ] || rm -rf "$old"; done
      ls -1t "$A"/logs/*.log 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null
      exit 0
    ) > "$L" 2>&1
    rc=$?
    case $rc in 0) st=live ;; 2) st=rolledback ;; *) st=failed ;; esac
    sha=$(grep -m1 '^== commit' "$L" | awk '{print $3}'); msg=$(grep -m1 '^== commit' "$L" | cut -d' ' -f4-)
    echo "$(date +%s) $ts ${sha:--} $st ${msg:-}" >> "$A/deploys.log"
    if [ "$st" != live ] && [ -n "${TOPIC:-}" ]; then curl -fsS -m 10 -H "Title: Deploy of $NAME $st" -H "Priority: high" -H "Tags: warning" --data-binary @"$L" "$TOPIC" >/dev/null 2>&1; fi
    exit $rc
    """#

    /// Restarts the live release (also used by `@reboot`).
    static let startScript = #"""
    #!/bin/bash
    A="$(cd "$(dirname "$0")" && pwd)"; . "$A/app.env"
    [ -f "$A/app.pid" ] && kill -TERM -- "-$(cat "$A/app.pid")" 2>/dev/null; sleep 1; rm -f "$A/app.pid"
    [ -n "$START" ] && [ -d "$A/current" ] || exit 0
    ( cd "$A/current" && exec setsid nohup sh -c "$START" >> "$A/app.log" 2>&1 < /dev/null ) & echo $! > "$A/app.pid"
    """#

    static func dir(_ name: String) -> String { "\(root)/\(name)" }

    static func env(_ a: App, topic: String) -> String {
        [("NAME", a.name), ("REPO", a.repo), ("BRANCH", a.branch), ("BUILD", a.build), ("START", a.start), ("HEALTH", a.health),
         ("KEEP", String(max(1, a.keep))), ("TOPIC", topic)].map { "\($0)=\(q($1))" }.joined(separator: "\n")
    }

    /// Saves (or updates) the app and its schedule lines; does not deploy. Prints `@@ok` or `@@nogit`.
    public static func saveCommand(_ a: App, topic: String) -> String {
        let d = dir(a.name)
        let cron = "\(d)/deploy.sh --if-changed >/dev/null 2>&1 # deckhand-deploy:\(a.name)"
        let boot = "@reboot \(d)/start.sh >/dev/null 2>&1 # deckhand-deploy:\(a.name)"
        return """
        command -v git >/dev/null 2>&1 || { echo '@@nogit'; exit 0; }
        D=\(d); mkdir -p "$D" && chmod 700 "$D"
        printf '%s\\n' \(q(env(a, topic: topic))) > "$D/app.env"
        printf '%s\\n' \(q(deployScript)) > "$D/deploy.sh" && chmod 700 "$D/deploy.sh"
        printf '%s\\n' \(q(startScript)) > "$D/start.sh" && chmod 700 "$D/start.sh"
        { crontab -l 2>/dev/null | grep -v '# deckhand-deploy:\(a.name)$'; \(a.autoDeploy ? "echo \"* * * * * \(cron)\";" : "") echo "\(boot)"; } | crontab - 2>/dev/null
        echo '@@ok'
        """
    }

    /// Deploys now (detached; the app polls the status). Prints `@@started`.
    public static func deployCommand(_ name: String) -> String {
        "nohup \(dir(name))/deploy.sh >/dev/null 2>&1 < /dev/null & echo '@@started'"
    }

    /// Makes an older release live again and restarts it.
    public static func rollbackCommand(_ name: String, release: String) -> String {
        let r = release.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return """
        A=\(dir(name)); R="$A/releases/\(r)"; [ -d "$R" ] || { echo '@@failed missing release'; exit 0; }
        ln -sfn "$R" "$A/current.tmp" && mv -Tf "$A/current.tmp" "$A/current" && bash "$A/start.sh"
        echo "$(date +%s) $(date -u +%Y%m%d-%H%M%S) \(r.split(separator: "-").last.map(String.init) ?? "-") rollback back to \(r)" >> "$A/deploys.log"
        echo '@@ok'
        """
    }

    /// Stops the app, removes its schedule and everything in its folder.
    public static func removeCommand(_ name: String) -> String {
        """
        A=\(dir(name)); [ -f "$A/app.pid" ] && kill -TERM -- "-$(cat "$A/app.pid")" 2>/dev/null
        crontab -l 2>/dev/null | grep -v '# deckhand-deploy:\(name)$' | crontab - 2>/dev/null
        rm -rf "$A"; echo '@@ok'
        """
    }

    /// Every app with its settings, live release, releases, recent deploys and whether it runs.
    public static let statusCommand = """
    [ -d \(root) ] || exit 0
    for A in \(root)/*/; do A=${A%/}; [ -f "$A/app.env" ] || continue
      ( . "$A/app.env"
        printf '@@app %s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$NAME" "$REPO" "$BRANCH" "$KEEP" "$HEALTH" "$(printf '%s' "$BUILD" | tr '\\t\\n' '  ')" "$(printf '%s' "$START" | tr '\\t\\n' '  ')"
        crontab -l 2>/dev/null | grep -q "deploy.sh --if-changed.*# deckhand-deploy:$NAME\\$" && echo '@@auto'
        [ -L "$A/current" ] && echo "@@current $(basename "$(readlink "$A/current")")"
        if [ -f "$A/app.pid" ] && kill -0 "$(cat "$A/app.pid")" 2>/dev/null; then echo '@@running'; fi
        pgrep -f "$A/deploy.sh" >/dev/null 2>&1 && echo '@@deploying'
        ls -1 "$A/releases" 2>/dev/null | sort -r | sed 's/^/@@release /'
        [ -f "$A/deploys.log" ] && tail -n 20 "$A/deploys.log" | sed 's/^/@@deploy /' )
    done
    true
    """

    public struct Deploy: Sendable, Hashable, Identifiable {
        public var id: String { stamp }
        public var date: Date
        /// `20261111-210000`: also the log file name.
        public var stamp: String
        public var sha: String
        /// live, failed, rolledback, rollback
        public var state: String
        public var message: String
    }

    public struct Status: Sendable, Hashable, Identifiable {
        public var app: App
        public var current: String?
        public var running = false
        public var deploying = false
        public var releases: [String] = []
        public var deploys: [Deploy] = []
        public var id: String { app.name }
        /// Short commit of the live release (`<stamp>-<sha>`).
        public var liveCommit: String? { current?.split(separator: "-").last.map(String.init) }
    }

    public static func parseStatus(_ out: String) -> [Status] {
        var all: [Status] = []
        for line in out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("@@app ") {
                let f = line.dropFirst(6).components(separatedBy: "\t")
                guard f.count >= 7 else { continue }
                all.append(Status(app: App(name: f[0], repo: f[1], branch: f[2], build: f[5], start: f[6], health: f[4], keep: Int(f[3]) ?? 5)))
                continue
            }
            guard !all.isEmpty else { continue }
            let i = all.count - 1
            if line == "@@auto" { all[i].app.autoDeploy = true }
            else if line == "@@running" { all[i].running = true }
            else if line == "@@deploying" { all[i].deploying = true }
            else if line.hasPrefix("@@current ") { all[i].current = String(line.dropFirst(10)) }
            else if line.hasPrefix("@@release ") { all[i].releases.append(String(line.dropFirst(10))) }
            else if line.hasPrefix("@@deploy ") {
                let p = line.dropFirst(9).split(separator: " ", maxSplits: 4).map(String.init)
                guard p.count >= 4, let t = Double(p[0]) else { continue }
                all[i].deploys.append(Deploy(date: Date(timeIntervalSince1970: t), stamp: p[1], sha: p[2], state: p[3], message: p.count > 4 ? p[4] : ""))
            }
        }
        for i in all.indices { all[i].deploys.reverse() }
        return all
    }

    public static func logCommand(_ name: String, stamp: String) -> String {
        "tail -n 300 \(dir(name))/logs/\(stamp.filter { $0.isNumber || $0 == "-" }).log 2>/dev/null"
    }

    public static func appLogCommand(_ name: String) -> String { "tail -n 200 \(dir(name))/app.log 2>/dev/null" }

    /// The server's own SSH public key (created if missing) — to add as a read-only deploy key for private repos.
    public static let deployKeyCommand = """
    [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C "deckhand-deploy@$(hostname)" -f ~/.ssh/id_ed25519
    cat ~/.ssh/id_ed25519.pub
    """
}
