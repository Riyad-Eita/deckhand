import Foundation

/// Real backups without a subscription: restic on the server, to a folder, an SFTP host or S3-compatible storage
/// (S3, Backblaze B2, Cloudflare R2, Wasabi, Hetzner). Runs from cron, keeps a retention, pushes when it fails;
/// snapshots can be browsed and restored from the app.
public enum Backups {
    static let dir = "$HOME/.deckhand/backup"
    static let resticVersion = "0.17.3"
    static let cronTag = "# deckhand-backup"

    public enum Target: Sendable, Hashable {
        /// A folder on this server (or a mounted disk).
        case folder(String)
        /// `user@host:/path`, reached with the server's own SSH key.
        case sftp(String)
        /// S3-compatible: endpoint like `https://s3.eu-central-003.backblazeb2.com`, bucket, keys.
        case s3(endpoint: String, bucket: String, accessKey: String, secretKey: String)

        var repository: String {
            switch self {
            case .folder(let p): p
            case .sftp(let s): "sftp:" + s
            case .s3(let e, let b, _, _): "s3:" + e.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + b
            }
        }

        var environment: [(String, String)] {
            if case .s3(_, _, let a, let s) = self { return [("AWS_ACCESS_KEY_ID", a), ("AWS_SECRET_ACCESS_KEY", s)] }
            return []
        }

        public var label: String {
            switch self {
            case .folder(let p): p
            case .sftp(let s): s
            case .s3(let e, let b, _, _): "\(b) · \(URL(string: e)?.host ?? e)"
            }
        }
    }

    public struct Plan: Sendable, Hashable {
        public var paths: [String]
        public var excludes: [String] = ["node_modules", ".cache", "*.tmp"]
        public var target: Target
        public var password: String
        /// Hour of the day (server time) for the nightly run.
        public var hour = 3
        public var keepDaily = 7, keepWeekly = 4, keepMonthly = 6
        /// ntfy topic for failure pushes (empty: none).
        public var topic = ""

        public init(paths: [String], target: Target, password: String) {
            self.paths = paths; self.target = target; self.password = password
        }
    }

    /// A long random repository password (shown once in the app; without it the backups can't be read).
    public static func newPassword() -> String {
        let a = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        return (0..<6).map { _ in String((0..<5).map { _ in a.randomElement()! }) }.joined(separator: "-")
    }

    static func q(_ s: String) -> String { ShellQuote.quote(s) }

    /// The nightly script: backup, then forget + prune by the retention; a push when anything fails.
    static let runScript = #"""
    #!/bin/sh
    # Deckhand backups — run by cron. Managed by the Deckhand app.
    D="$HOME/.deckhand/backup"; . "$D/env"; export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    R="$HOME/.local/bin/restic"; [ -x "$R" ] || R=restic
    exec 9>"$D/.lock"; flock -n 9 2>/dev/null || { command -v flock >/dev/null 2>&1 && exit 0; }
    start=$(date +%s)
    {
      echo "== $(date -u '+%Y-%m-%d %H:%M:%S UTC') backup"
      "$R" backup --files-from "$D/paths" --exclude-file "$D/excludes" --tag deckhand --json 2>&1 | tail -n 1
      b=$?
      "$R" forget --tag deckhand --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune --quiet 2>&1 | tail -n 5
      f=$?
    } > "$D/last.log" 2>&1
    ok=1; grep -q '"message_type":"summary"' "$D/last.log" || ok=0
    echo "$start $(date +%s) $ok" >> "$D/runs"; tail -n 200 "$D/runs" > "$D/runs.tmp" && mv "$D/runs.tmp" "$D/runs"
    if [ "$ok" = 0 ] && [ -n "${TOPIC:-}" ]; then
      curl -fsS -m 10 -H "Title: Backup failed on $(hostname)" -H "Priority: high" -H "Tags: warning" --data-binary @"$D/last.log" "$TOPIC" >/dev/null 2>&1
    fi
    """#

    /// Installs restic if needed (static binary in ~/.local/bin, no root), writes the setup, initialises the
    /// repository (unless it exists) and adds the cron line. Prints `@@restic <version>`, `@@init` / `@@exists`,
    /// `@@nocron`, `@@ok`, or `@@failed <why>`.
    static func envFile(_ p: Plan) -> String {
        ([("RESTIC_REPOSITORY", p.target.repository), ("RESTIC_PASSWORD_FILE", "$HOME/.deckhand/backup/password")] + p.target.environment
                   + [("KEEP_DAILY", "\(p.keepDaily)"), ("KEEP_WEEKLY", "\(p.keepWeekly)"), ("KEEP_MONTHLY", "\(p.keepMonthly)"), ("TOPIC", p.topic)])
            .map { k, v in k == "RESTIC_PASSWORD_FILE" ? "\(k)=\"\(v)\"" : "\(k)=\(q(v))" }.joined(separator: "\n")
    }

    /// The plan's excludes, plus the repository folder itself when it lies inside a backed-up folder.
    static func excludes(_ p: Plan) -> [String] {
        if case .folder(let f) = p.target { return p.excludes + [f] }
        return p.excludes
    }

    public static func setupCommand(_ p: Plan) -> String {
        let env = envFile(p)
        let paths = p.paths.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        let hour = max(0, min(23, p.hour))
        return """
        D=\(dir); mkdir -p "$D" && chmod 700 "$D"
        R="$HOME/.local/bin/restic"
        if ! command -v restic >/dev/null 2>&1 && [ ! -x "$R" ]; then
          case "$(uname -m)" in x86_64|amd64) A=amd64 ;; aarch64|arm64) A=arm64 ;; armv7l) A=arm ;; *) echo "@@failed unsupported CPU $(uname -m)"; exit 0 ;; esac
          mkdir -p "$HOME/.local/bin"
          U="https://github.com/restic/restic/releases/download/v\(resticVersion)/restic_\(resticVersion)_linux_$A.bz2"
          if command -v curl >/dev/null 2>&1; then curl -fsSL "$U" -o "$R.bz2"; else wget -qO "$R.bz2" "$U"; fi \\
            && { if command -v bunzip2 >/dev/null 2>&1; then bunzip2 -f "$R.bz2"
                 else python3 -c 'import bz2,sys; open(sys.argv[2],"wb").write(bz2.decompress(open(sys.argv[1],"rb").read()))' "$R.bz2" "$R" && rm -f "$R.bz2"; fi; } \\
            && chmod 755 "$R" || { rm -f "$R" "$R.bz2"; echo '@@failed could not download restic'; exit 0; }
        fi
        [ -x "$R" ] || R=restic
        echo "@@restic $("$R" version 2>/dev/null | awk '{print $2}')"
        umask 077
        printf '%s' \(q(p.password)) > "$D/password"
        printf '%s\\n' \(q(env)) > "$D/env"
        printf '%s\\n' \(q(paths)) > "$D/paths"
        printf '%s\\n' \(q(excludes(p).joined(separator: "\n"))) > "$D/excludes"
        printf '%s\\n' \(q(runScript)) > "$D/run.sh" && chmod 700 "$D/run.sh"
        . "$D/env"; export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        case "$RESTIC_REPOSITORY" in /*) mkdir -p "$RESTIC_REPOSITORY" ;; esac
        if "$R" cat config >/dev/null 2>&1; then echo '@@exists'
        else out=$("$R" init 2>&1) && echo '@@init' || {
          case "$out" in *already*|*exist*) echo '@@failed This location already holds backups made with another password. Choose an empty folder or bucket path.' ;;
          *) echo "@@failed $(printf '%s' "$out" | tail -n 1)" ;; esac; exit 0; }; fi
        command -v crontab >/dev/null 2>&1 || { echo '@@nocron'; echo '@@ok'; exit 0; }
        { crontab -l 2>/dev/null | grep -v 'deckhand/backup/run.sh'; echo "\(Int.random(in: 0...59)) \(hour) * * * $HOME/.deckhand/backup/run.sh >/dev/null 2>&1 \(cronTag)"; } | crontab -
        echo '@@ok'
        """
    }

    /// Runs a backup now, detached (it keeps going if the app disconnects).
    public static let runNowCommand = """
    [ -x \(dir)/run.sh ] || { echo '@@missing'; exit 0; }
    nohup sh \(dir)/run.sh >/dev/null 2>&1 < /dev/null & echo '@@started'
    """

    /// Prefix that loads the repository settings for interactive commands.
    static let load = """
    D=\(dir); [ -f "$D/env" ] || { echo '@@missing'; exit 0; }
    . "$D/env"; export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    R="$HOME/.local/bin/restic"; [ -x "$R" ] || R=restic
    """

    /// Settings, schedule, last runs and the snapshots (JSON on the `@@snapshots` line).
    public static let statusCommand = """
    \(load)
    echo '@@configured'
    echo "@@repo $RESTIC_REPOSITORY"
    echo "@@keep $KEEP_DAILY $KEEP_WEEKLY $KEEP_MONTHLY"
    sed 's/^/@@path /' "$D/paths"
    crontab -l 2>/dev/null | grep 'deckhand/backup/run.sh' | awk '{print "@@cron", $1, $2}'
    pgrep -f 'deckhand/backup/run.sh' >/dev/null 2>&1 && echo '@@running'
    [ -f "$D/runs" ] && tail -n 10 "$D/runs" | sed 's/^/@@run /'
    echo "@@snapshots $("$R" snapshots --tag deckhand --json 2>/dev/null | tr -d '\\n')"
    true
    """

    /// One folder of a snapshot (not recursive). JSON lines.
    public static func listCommand(snapshot: String, path: String) -> String {
        "\(load)\n\"$R\" ls --json \(q(snapshot.filter(\.isHexDigit))) \(q(path)) 2>&1 | head -n 2000"
    }

    /// Restores `path` from a snapshot into a new folder (never over the live files). Prints `@@restored <dir>`.
    public static func restoreCommand(snapshot: String, path: String, date: Date = Date()) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        return """
        \(load)
        T="$HOME/restored-\(stamp)"; mkdir -p "$T"
        "$R" restore \(q(snapshot.filter(\.isHexDigit))) --include \(q(path)) --target "$T" 2>&1 | tail -n 3 && echo "@@restored $T"
        """
    }

    /// Removes the schedule and the settings (the repository and its snapshots stay where they are).
    public static let removeCommand = """
    crontab -l 2>/dev/null | grep -v 'deckhand/backup/run.sh' | crontab - 2>/dev/null; rm -rf \(dir); echo '@@ok'
    """

    // MARK: - Parsing

    public struct Snapshot: Sendable, Hashable, Identifiable, Decodable {
        public var id: String
        public var shortID: String
        public var time: Date
        public var paths: [String]
        public var hostname: String?
        public var addedBytes: Int64?
        public var totalBytes: Int64?

        enum CodingKeys: String, CodingKey { case id, short_id, time, paths, hostname, summary }
        enum SummaryKeys: String, CodingKey { case data_added, total_bytes_processed }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            shortID = (try? c.decode(String.self, forKey: .short_id)) ?? String(id.prefix(8))
            let t = try c.decode(String.self, forKey: .time)
            time = Backups.date(t) ?? Date(timeIntervalSince1970: 0)
            paths = (try? c.decode([String].self, forKey: .paths)) ?? []
            hostname = try? c.decode(String.self, forKey: .hostname)
            if let s = try? c.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary) {
                addedBytes = try? s.decode(Int64.self, forKey: .data_added)
                totalBytes = try? s.decode(Int64.self, forKey: .total_bytes_processed)
            }
        }
    }

    /// restic writes RFC 3339 times with nanoseconds.
    static func date(_ s: String) -> Date? {
        var t = s
        if let dot = t.firstIndex(of: "."), let zone = t[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            t.removeSubrange(dot..<zone)
        }
        return ISO8601DateFormatter().date(from: t)
    }

    public struct Run: Sendable, Hashable { public var start: Date; public var end: Date; public var ok: Bool }

    public struct Status: Sendable, Hashable {
        public var configured = false
        public var repository = ""
        public var paths: [String] = []
        public var keep = (daily: 7, weekly: 4, monthly: 6)
        /// Minute and hour of the cron line.
        public var schedule: (minute: Int, hour: Int)?
        public var running = false
        public var runs: [Run] = []
        public var snapshots: [Snapshot] = []
        public var snapshotsError = false

        public static func == (a: Status, b: Status) -> Bool { a.configured == b.configured && a.snapshots == b.snapshots && a.runs == b.runs && a.running == b.running }
        public func hash(into h: inout Hasher) { h.combine(configured); h.combine(snapshots) }
        public var lastRun: Run? { runs.last }
    }

    public static func parseStatus(_ out: String) -> Status {
        var s = Status()
        for line in out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let (k, v): (String, String) = {
                guard let sp = line.firstIndex(of: " ") else { return (line, "") }
                return (String(line[..<sp]), String(line[line.index(after: sp)...]))
            }()
            switch k {
            case "@@configured": s.configured = true
            case "@@repo": s.repository = v
            case "@@path": s.paths.append(v)
            case "@@keep":
                let p = v.split(separator: " ").compactMap { Int($0) }
                if p.count == 3 { s.keep = (p[0], p[1], p[2]) }
            case "@@cron":
                let p = v.split(separator: " ").compactMap { Int($0) }
                if p.count == 2 { s.schedule = (p[0], p[1]) }
            case "@@running": s.running = true
            case "@@run":
                let p = v.split(separator: " ").compactMap { Double($0) }
                if p.count == 3 { s.runs.append(Run(start: Date(timeIntervalSince1970: p[0]), end: Date(timeIntervalSince1970: p[1]), ok: p[2] == 1)) }
            case "@@snapshots":
                if let data = v.data(using: .utf8), let snaps = try? JSONDecoder().decode([Snapshot].self, from: data) {
                    s.snapshots = snaps.sorted { $0.time > $1.time }
                } else if !v.isEmpty { s.snapshotsError = true }
            default: break
            }
        }
        return s
    }

    public struct Node: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public var name: String
        public var path: String
        public var isDirectory: Bool
        public var size: Int64?
    }

    /// The direct children of `parent` from `restic ls --json` output.
    public static func parseList(_ out: String, parent: String) -> [Node] {
        let base = parent == "/" ? "/" : parent.hasSuffix("/") ? parent : parent + "/"
        var nodes: [Node] = []
        for line in out.split(separator: "\n") {
            guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["struct_type"] as? String) == "node", let path = obj["path"] as? String, let name = obj["name"] as? String,
                  path.hasPrefix(base), !path.dropFirst(base.count).contains("/") else { continue }
            nodes.append(Node(name: name, path: path, isDirectory: (obj["type"] as? String) == "dir", size: (obj["size"] as? NSNumber)?.int64Value))
        }
        return nodes.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    /// Folders worth backing up that exist on this server, for the wizard. Prints one per line.
    public static let suggestionsCommand = """
    printf '%s\\n' "$HOME"
    for d in /srv /var/www /opt /etc/nginx /etc/caddy /home; do [ -d "$d" ] && [ -r "$d" ] && [ "$d" != "$HOME" ] && printf '%s\\n' "$d"; done
    true
    """
}
