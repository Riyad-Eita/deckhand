import Foundation

/// What changed on a server, and when. A small snapshot script (cron, every 15 minutes) writes the server's state —
/// packages, services, open ports, containers, cron jobs, users, readable files in /etc — into a private git
/// repository in `~/.deckhand/history`, so "it worked yesterday" becomes a diff.
public enum ChangeHistory {
    static let dir = "$HOME/.deckhand/history"

    /// The snapshot script: writes the state to `next/`, stores `diff -rN -U0 state next` as `changes/<epoch>.diff`
    /// (first line: `# <subject>`), then keeps `next/` as the new state. Needs only sh and diff, no git. `ETC`
    /// overrides /etc (tests). The subject says who changed things when it can tell: package manager runs, Deckhand
    /// config changes, agent tasks.
    static let snapshotScript = #"""
    #!/bin/sh
    # Deckhand change history — run by cron every 15 minutes.
    command -v diff >/dev/null 2>&1 || exit 0
    D="$HOME/.deckhand/history"; ETC="${ETC:-/etc}"
    mkdir -p "$D/changes" && cd "$D" || exit 0
    rm -rf next && mkdir -p next/etc && cd next || exit 0
    if command -v dpkg-query >/dev/null 2>&1; then dpkg-query -W -f '${Package} ${Version}\n' 2>/dev/null | sort > packages.txt
    elif command -v rpm >/dev/null 2>&1; then rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null | sort > packages.txt
    elif command -v apk >/dev/null 2>&1; then apk info -v 2>/dev/null | sort > packages.txt; fi
    if command -v systemctl >/dev/null 2>&1; then
      systemctl list-units --type=service --all --no-legend --plain 2>/dev/null | awk '$1 ~ /\.service$/ && $1 !~ /@/ {print $1, $3, $4}' | sort > services.txt

      # No D-Bus (containers): at least the enabled ones.
      [ -s services.txt ] || ls "$ETC"/systemd/system/*.wants 2>/dev/null | grep '\.service$' | grep -v @ | sort -u | sed 's/$/ enabled/' > services.txt
    fi
    (ss -tlnH 2>/dev/null || netstat -tln 2>/dev/null | tail -n +3) | awk '{print $4}' | sort -u > ports.txt
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      docker ps -a --format '{{.Names}} {{.Image}} {{.State}}' 2>/dev/null | sort > containers.txt
      docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null | sort > images.txt
    fi
    { crontab -l 2>/dev/null | grep -v '^#' | grep -v 'deckhand/' | grep -v '^$'; ls "$ETC/cron.d" 2>/dev/null | sed 's|^|cron.d/|'; } > cron.txt
    { getent passwd 2>/dev/null | awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)$/ {print $1, $3, $7}'
      getent group sudo wheel admin docker 2>/dev/null | awk -F: '{print "group:" $1, $4}'; } > users.txt
    (cd "$ETC" 2>/dev/null && find . -type f -size -64k ! -name '*.key' ! -name '*.pem' ! -name '*.crt' ! -name '*shadow*' \
      ! -name '*.db' ! -name '*.cache' ! -name '*.bin' ! -path './ssl/*' ! -path './letsencrypt/*' ! -path './ssh/ssh_host_*' \
      ! -name 'adjtime' ! -name 'mtab' ! -name 'ld.so.cache' 2>/dev/null | while IFS= read -r f; do [ -r "$f" ] && printf '%s\n' "$f"; done \
      | tar -cf - -T - 2>/dev/null) | (cd etc && tar -xf - 2>/dev/null)
    cd "$D" || exit 0
    ts=$(date +%s); while [ -e "changes/$ts.diff" ]; do ts=$((ts + 1)); done
    if [ ! -d state ]; then
      mv next state; echo '# start' > "changes/$ts.diff"; touch .mark
      wc -l < /var/log/apt/history.log > .apt 2>/dev/null || echo 0 > .apt
      exit 0
    fi
    diff -rN -U0 state next 2>/dev/null | head -c 2000000 > .diff
    if [ -s .diff ]; then
      who=
      now=$(wc -l < /var/log/apt/history.log 2>/dev/null || echo 0); prev=$(cat .apt 2>/dev/null || echo "$now")
      [ "$now" -lt "$prev" ] && prev=0
      apt=$(tail -n +$((prev + 1)) /var/log/apt/history.log 2>/dev/null | sed -n 's/^Commandline: //p' | tail -n 3 | tr '\n' ';' | sed 's/;$//')
      echo "$now" > .apt
      [ -n "$apt" ] && who="$who|pkg $apt"
      if [ -f .mark ]; then
        ch=$(find /var/backups/deckhand -mindepth 1 -maxdepth 1 -newer .mark 2>/dev/null | wc -l | tr -d ' ')
        [ "$ch" -gt 0 ] 2>/dev/null && who="$who|deckhand $ch"
        runs=$(find "$HOME/.deckhand/runs" -mindepth 1 -maxdepth 1 -newer .mark 2>/dev/null | wc -l | tr -d ' ')
        [ "$runs" -gt 0 ] 2>/dev/null && who="$who|agent $runs"
      fi
      { echo "# snapshot$who"; cat .diff; } > "changes/$ts.diff"
      touch .mark
    fi
    rm -rf state .diff && mv next state
    ls -1 changes | sort -r | tail -n +2001 | sed 's|^|changes/|' | xargs rm -f 2>/dev/null
    true
    """#

    public static var installCommand: String {
        """
        command -v diff >/dev/null 2>&1 || { echo '@@nodiff'; exit 0; }
        mkdir -p \(dir) && chmod 700 \(dir)
        printf '%s\\n' \(ShellQuote.quote(snapshotScript)) > \(dir)/snap.sh && chmod 700 \(dir)/snap.sh
        sh \(dir)/snap.sh
        command -v crontab >/dev/null 2>&1 || { echo '@@nocron'; exit 0; }
        { crontab -l 2>/dev/null | grep -v 'deckhand/history/snap.sh'; echo "*/15 * * * * $HOME/.deckhand/history/snap.sh >/dev/null 2>&1 # deckhand-history"; } | crontab -
        echo '@@ok'
        """
    }

    public static let uninstallCommand = """
    crontab -l 2>/dev/null | grep -v 'deckhand/history/snap.sh' | crontab - 2>/dev/null; rm -rf \(dir); echo '@@ok'
    """

    /// Lists every change file in `files` (newest first) as `@@c <id> <epoch> <subject>` plus one `M\t<path>` per file.
    static func listing(_ files: String) -> String {
        """
        for f in \(files); do [ -f "$f" ] || continue; id=$(basename "$f" .diff)
          printf '@@c %s %s %s\\n' "$id" "$id" "$(head -n 1 "$f" | sed 's/^# //')"
          awk '/^diff /{p=$NF; sub(/^next\\//, "", p); print "M\\t" p}' "$f"
        done
        """
    }

    /// Takes a snapshot now (when installed), then lists the latest ones with the files each changed.
    public static let timelineCommand = """
    if command -v diff >/dev/null 2>&1; then echo '@@diff yes'; else echo '@@diff no'; fi
    crontab -l 2>/dev/null | grep -q 'deckhand/history/snap.sh' && echo '@@cron'
    [ -f \(dir)/snap.sh ] || exit 0
    echo '@@installed'
    sh \(dir)/snap.sh
    cd \(dir)/changes 2>/dev/null || exit 0
    \(listing("$(ls -1 | sort -r | head -n 300)"))
    true
    """

    /// The changes of one snapshot.
    public static func showCommand(_ id: String) -> String {
        let n = id.filter(\.isNumber)
        return "tail -n +2 \(dir)/changes/\(n).diff 2>/dev/null | head -c 400000"
    }

    /// Everything that changed after `date`: the snapshots, then their diffs (oldest first, so they add up).
    public static func sinceCommand(_ date: Date, limit: Int = 400_000) -> String {
        let ts = Int(date.timeIntervalSince1970)
        return """
        cd \(dir)/changes 2>/dev/null || exit 0
        list=$(ls -1 | sort | awk -F. '$1 > \(ts)')
        \(listing("$(printf '%s\\n' $list | sort -r)"))
        for f in $list; do tail -n +2 "$f"; done | head -c \(limit)
        true
        """
    }

    // MARK: - Parsing

    public enum Category: String, Sendable, CaseIterable {
        case packages = "Packages", services = "Services", ports = "Open ports", containers = "Containers", images = "Images"
        case cron = "Cron jobs", users = "Users", config = "Config files"

        public init?(path: String) {
            switch path {
            case "packages.txt": self = .packages
            case "services.txt": self = .services
            case "ports.txt": self = .ports
            case "containers.txt": self = .containers
            case "images.txt": self = .images
            case "cron.txt": self = .cron
            case "users.txt": self = .users
            default:
                guard path.hasPrefix("etc/") else { return nil }
                self = .config
            }
        }

        /// Lines are "key rest…": a removed and an added line with the same key are one change.
        var keyed: Bool { [.packages, .services, .containers, .images, .users].contains(self) }
    }

    public struct Snapshot: Sendable, Hashable, Identifiable {
        public var id: String { stamp }
        public var stamp: String
        public var date: Date
        /// Package manager commands, Deckhand changes, agent tasks behind this snapshot.
        public var causes: [Cause]
        public var isStart: Bool
        public var files: [String]

        public var categories: [Category: Int] {
            var c: [Category: Int] = [:]
            for f in files { if let k = Category(path: f) { c[k, default: 0] += 1 } }
            return c
        }
    }

    public enum Cause: Sendable, Hashable {
        case packageManager(String)
        case deckhand(Int)
        case agent(Int)
    }

    public struct Timeline: Sendable, Hashable {
        /// `diff` is there (it is on practically every Linux).
        public var hasDiff = false
        public var installed = false
        public var cron = false
        public var snapshots: [Snapshot] = []
    }

    static func parseSubject(_ s: String) -> (start: Bool, causes: [Cause]) {
        let parts = s.components(separatedBy: "|")
        var causes: [Cause] = []
        for p in parts.dropFirst() {
            if p.hasPrefix("pkg ") { causes.append(.packageManager(String(p.dropFirst(4)))) }
            else if p.hasPrefix("deckhand "), let n = Int(p.dropFirst(9)) { causes.append(.deckhand(n)) }
            else if p.hasPrefix("agent "), let n = Int(p.dropFirst(6)) { causes.append(.agent(n)) }
        }
        return (parts.first == "start", causes)
    }

    static func parseCommit(_ line: String) -> Snapshot? {
        let f = line.dropFirst(4).split(separator: " ", maxSplits: 2).map(String.init)
        guard f.count >= 2, let t = Double(f[1]) else { return nil }
        let subject = parseSubject(f.count > 2 ? f[2] : "")
        return Snapshot(stamp: f[0], date: Date(timeIntervalSince1970: t), causes: subject.causes, isStart: subject.start, files: [])
    }

    public static func parseTimeline(_ output: String) -> Timeline {
        var t = Timeline()
        for line in output.components(separatedBy: "\n") {
            if line == "@@diff yes" { t.hasDiff = true }
            else if line == "@@installed" { t.installed = true }
            else if line == "@@cron" { t.cron = true }
            else if line.hasPrefix("@@c ") { if let s = parseCommit(line) { t.snapshots.append(s) } }
            else if !t.snapshots.isEmpty, let tab = line.firstIndex(of: "\t") {
                t.snapshots[t.snapshots.count - 1].files.append(String(line[line.index(after: tab)...]))
            }
        }
        return t
    }

    public struct FileDiff: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public var path: String
        public var added: [String] = []
        public var removed: [String] = []
        public var isNew = false
        public var isDeleted = false
        public var category: Category? { Category(path: path) }
    }

    public struct Change: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable { case added, removed, changed }
        public var id: String { "\(key)|\(old ?? "")|\(new ?? "")" }
        public var kind: Kind
        public var key: String
        public var old: String?
        public var new: String?
    }

    /// Parses `diff -rN -U0 state next` output. Diffs of several snapshots in a row add up: a line that was added
    /// and later removed again cancels out, so "1.24 → 1.25 → 1.26" becomes "1.24 → 1.26".
    public static func parseDiff(_ output: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var index: [String: Int] = [:]
        var current: Int?
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("diff ") {
                var path = String(line.split(separator: " ").last ?? "")
                if path.hasPrefix("next/") { path.removeFirst(5) }
                if let i = index[path] { current = i } else {
                    index[path] = files.count; current = files.count
                    files.append(FileDiff(path: path))
                }
            } else if let i = current {
                if line.hasPrefix("--- ") {
                    if line.contains("1970-01-01") && files[i].removed.isEmpty && files[i].added.isEmpty { files[i].isNew = true }
                } else if line.hasPrefix("+++ ") {
                    if line.contains("1970-01-01") { files[i].isDeleted = true; files[i].isNew = false } else { files[i].isDeleted = false }
                } else if line.hasPrefix("@@") {
                    continue
                } else if line.hasPrefix("+") {
                    let l = String(line.dropFirst())
                    if let r = files[i].removed.firstIndex(of: l) { files[i].removed.remove(at: r) } else { files[i].added.append(l) }
                } else if line.hasPrefix("-") {
                    let l = String(line.dropFirst())
                    if let r = files[i].added.firstIndex(of: l) { files[i].added.remove(at: r) } else { files[i].removed.append(l) }
                }
            }
        }
        return files.filter { !$0.added.isEmpty || !$0.removed.isEmpty || $0.isNew || $0.isDeleted }
    }

    /// Readable changes for a state file: "nginx 1.24 → 1.26", added and removed entries.
    public static func changes(in file: FileDiff) -> [Change] {
        guard let cat = file.category, cat != .config else { return [] }
        func split(_ l: String) -> (String, String) {
            guard cat.keyed, let sp = l.firstIndex(of: " ") else { return (l, "") }
            return (String(l[..<sp]), String(l[l.index(after: sp)...]))
        }
        var removed: [String: String] = [:]
        var order: [String] = []
        for l in file.removed where !l.isEmpty { let (k, v) = split(l); removed[k] = v; order.append(k) }
        var out: [Change] = []
        var seen = Set<String>()
        for l in file.added where !l.isEmpty {
            let (k, v) = split(l)
            if cat.keyed, let old = removed[k] {
                out.append(Change(kind: .changed, key: k, old: old, new: v)); seen.insert(k)
            } else {
                out.append(Change(kind: .added, key: k, old: nil, new: v))
            }
        }
        for k in order where !seen.contains(k) { out.append(Change(kind: .removed, key: k, old: removed[k], new: nil)) }
        return out
    }

    /// A compact text of what changed, for an agent prompt.
    public static func summary(_ files: [FileDiff], limit: Int = 4_000) -> String {
        var lines: [String] = []
        for f in files {
            if f.category == .config {
                lines.append("\(f.isNew ? "new" : f.isDeleted ? "deleted" : "changed") /\(f.path) (+\(f.added.count) −\(f.removed.count))")
                for l in (f.removed.map { "  - " + $0 } + f.added.map { "  + " + $0 }).prefix(12) { lines.append(l) }
            } else {
                for c in changes(in: f) {
                    let what = f.category?.rawValue.lowercased() ?? f.path
                    switch c.kind {
                    case .added: lines.append("\(what): + \(c.key) \(c.new ?? "")")
                    case .removed: lines.append("\(what): − \(c.key) \(c.old ?? "")")
                    case .changed: lines.append("\(what): \(c.key) \(c.old ?? "") → \(c.new ?? "")")
                    }
                }
            }
        }
        let text = lines.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }
}
