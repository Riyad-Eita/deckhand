import Foundation

/// The morning briefing: once a day, at a time the user picks (in their own time zone), every server writes a short
/// report — updates, certificates and domains close to expiry, disk and memory trends, failed services and cron jobs,
/// failed logins — and can do a few small, safe fixes within the house rules. A server pushes only when something
/// needs the user (unless asked to always push). Runs from the server's crontab: the phone can be off.
///
/// Files in `~/.deckhand/briefing`: `config`, `run.sh`, `latest` (today's report), `previous`, `day` (last run date).
public enum Briefing {
    static let dir = "$HOME/.deckhand/briefing"
    static let cronTag = "# deckhand-briefing"

    public struct Config: Sendable, Hashable {
        public var hour: Int
        public var minute: Int
        /// The user's time zone (IANA), so the briefing comes at the same local time on every server, also across DST.
        public var timeZone: String
        /// ntfy topic URL; empty for no push.
        public var topic: String
        /// The server's name in Deckhand, shown in the push title.
        public var name: String
        /// Push only when something needs attention.
        public var quiet: Bool
        /// Do the small safe fixes (within the house rules).
        public var fixes: Bool

        public init(hour: Int = 7, minute: Int = 30, timeZone: String = TimeZone.current.identifier, topic: String = "",
                    name: String, quiet: Bool = true, fixes: Bool = false) {
            self.hour = max(0, min(hour, 23)); self.minute = max(0, min(minute, 59)); self.timeZone = timeZone
            self.topic = topic; self.name = name; self.quiet = quiet; self.fixes = fixes
        }

        var file: String {
            func q(_ s: String) -> String { ShellQuote.quote(s) }
            return """
            BHOUR=\(String(format: "%02d", hour))
            BTZ=\(q(timeZone))
            BTOPIC=\(q(topic))
            BNAME=\(q(name))
            BQUIET=\(quiet ? 1 : 0)
            BFIXES=\(fixes ? 1 : 0)
            """
        }

        static func parse(_ lines: [String]) -> Config? {
            var v: [String: String] = [:]
            for l in lines {
                guard let eq = l.firstIndex(of: "=") else { continue }
                var val = String(l[l.index(after: eq)...])
                if val.hasPrefix("'"), val.hasSuffix("'"), val.count >= 2 {
                    val = String(val.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
                }
                v[String(l[..<eq])] = val
            }
            guard let h = v["BHOUR"].flatMap({ Int($0) }) else { return nil }
            return Config(hour: h, minute: Int(v["BMIN"] ?? "") ?? 0, timeZone: v["BTZ"] ?? "UTC", topic: v["BTOPIC"] ?? "",
                          name: v["BNAME"] ?? "", quiet: v["BQUIET"] != "0", fixes: v["BFIXES"] == "1")
        }
    }

    // MARK: Server side

    /// Counts for the push, from a report: line 1 is `1` when something needs attention, line 2 the message.
    static let summaryAwk = #"""
    awk -v now="$(date +%s)" '
    function add(s) { msg = msg (msg == "" ? "" : " · ") s }
    /^@@section / { sec = $2; inlist = 0; insec = 0; next }
    sec == "updates" && /^@@list/ { inlist = 1; next }
    sec == "updates" && /^@@security/ { insec = 1; inlist = 0; next }
    sec == "updates" && /^@@reboot$/ { reboot = 1 }
    sec == "updates" && inlist && !/^@@/ && NF > 0 { upd++; if ($0 ~ /-security/) secu++ }
    sec == "updates" && insec && !/^@@/ && NF > 0 { secu++ }
    sec == "expiry" && /^@@status / {
      split(substr($0, 10), f, "\t")
      if (f[2] != "-" && f[2] != "" && (f[2] - now) / 86400 <= 14) certs++
      else if (f[4] != "-" && f[4] != "" && (f[4] - now) / 86400 <= 14) certs++
    }
    sec == "cron" && /^@@run / { last[$2] = $5 }
    sec == "cron" && /^@@missing / { cronbad++ }
    /^@@disk / { if ($3 + 0 >= 85) full = full (full == "" ? "" : ", ") $2 " " $3 "%" }
    /^@@mem / { if ($2 + 0 >= 90) mem = $2 }
    /^@@failed / { failed++ }
    /^@@fix / { fixes++ }
    END {
      for (k in last) if (last[k] != 0) cronbad++
      if (secu > 0) { add(secu " security update" (secu == 1 ? "" : "s")); att = 1 }
      if (reboot) { add("restart needed"); att = 1 }
      if (full != "") { add("disk " full); att = 1 }
      if (mem != "") { add("memory " int(mem) "%"); att = 1 }
      if (failed > 0) { add(failed " service" (failed == 1 ? "" : "s") " failed"); att = 1 }
      if (cronbad > 0) { add(cronbad " cron job" (cronbad == 1 ? "" : "s") " failing"); att = 1 }
      if (certs > 0) { add(certs " certificate" (certs == 1 ? "" : "s") " or domain" (certs == 1 ? "" : "s") " expiring"); att = 1 }
      if (!att) { msg = "All good" (upd > 0 ? " · " upd " update" (upd == 1 ? "" : "s") " waiting" : "") }
      else if (upd > secu && upd > 0) add((upd - secu) " other update" (upd - secu == 1 ? "" : "s"))
      if (fixes > 0) add(fixes " small fix" (fixes == 1 ? "" : "es") " done")
      print (att ? 1 : 0); print msg
    }' "$1"
    """#

    static var script: String {
        #"""
        #!/bin/bash
        # Deckhand morning briefing. Managed by the Deckhand app; change it there.
        BD="$HOME/.deckhand/briefing"; . "$BD/config" || exit 0
        export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
        today=$(TZ="$BTZ" date +%F)
        if [ -z "$FORCE" ]; then
          [ "$(TZ="$BTZ" date +%H)" = "$BHOUR" ] || exit 0
          [ "$(cat "$BD/day" 2>/dev/null)" = "$today" ] && exit 0
        fi
        echo "$today" > "$BD/day"
        allowed() {
          R="$HOME/.deckhand/rules/rules.json"
          [ -f "$R" ] || return 0
          grep -qE '"readOnly" *: *true' "$R" && return 1
          command -v python3 >/dev/null 2>&1 || return 0
          python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(1 if any(f and f in sys.argv[2] for f in (r.get("forbiddenCommands") or [])) else 0)' "$R" "$1"
        }
        summary() {
        \#(summaryAwk)
        }
        {
        echo "@@briefing $(date +%s) $(hostname)"
        echo "@@section updates"
        \#(PackageUpdates.statusCommand)
        echo "@@section expiry"
        \#(Expiry.statusCommand)
        echo "@@section cron"
        \#(CronWatch.statusCommand)
        echo "@@section system"
        df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | awk 'NR > 1 && $2 > 0 { gsub("%", "", $5); print "@@disk " $6 " " $5 " " $4 }'
        awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { if (t > 0) printf "@@mem %.1f\n", (t - a) * 100 / t }' /proc/meminfo 2>/dev/null
        [ -f "$BD/latest" ] && grep '^@@disk ' "$BD/latest" | sed 's/^@@disk /@@prevdisk /'
        S="$HOME/.deckhand/metrics/samples"
        [ -f "$S" ] && awk -v n="$(date +%s)" '{ if ($1 > n - 86400) { a += $3; c++ } else if ($1 > n - 172800) { b += $3; d++ } } END { if (c > 0 && d > 0) printf "@@memtrend %.1f %.1f\n", a / c, b / d }' "$S"
        command -v systemctl >/dev/null 2>&1 && systemctl --failed --no-legend --plain 2>/dev/null | awk '$1 != "" { print "@@failed " $1 }'
        if j=$(journalctl -q --since "-24h" -u ssh -u sshd 2>&1) && ! printf '%s' "$j" | grep -qiE 'insufficient permissions|no journal files'; then
          echo "@@logins $(printf '%s\n' "$j" | grep -cE 'Failed password|Invalid user')"
        elif [ -r /var/log/auth.log ]; then
          p="^($(date '+%b %e')|$(date -d yesterday '+%b %e' 2>/dev/null)|$(date +%F)|$(date -d yesterday +%F 2>/dev/null))"
          echo "@@logins $(grep -E "$p" /var/log/auth.log | grep -cE 'Failed password|Invalid user')"
        else
          echo "@@logins -"
        fi
        echo "@@section fixes"
        R="$HOME/.deckhand/rules/rules.json"
        if [ "$BFIXES" = 1 ]; then
          if [ -f "$R" ] && grep -qE '"readOnly" *: *true' "$R"; then
            echo "@@skipfix readonly"
          else
            n=$(find "$HOME/.deckhand/runs" -type f -mtime +30 2>/dev/null | wc -l | tr -d ' ')
            if [ "${n:-0}" -gt 0 ] && allowed "find ~/.deckhand/runs -mtime +30 -delete"; then
              find "$HOME/.deckhand/runs" -type f -mtime +30 -delete 2>/dev/null; echo "@@fix runs $n"
            fi
            if sudo -n true 2>/dev/null; then
              j=$(sudo -n du -sm /var/log/journal 2>/dev/null | cut -f1)
              if [ "${j:-0}" -gt 1024 ]; then
                if allowed "journalctl --vacuum-size=500M"; then
                  sudo -n journalctl --vacuum-size=500M >/dev/null 2>&1
                  echo "@@fix journal $j $(sudo -n du -sm /var/log/journal 2>/dev/null | cut -f1)"
                else echo "@@skipfix journal"; fi
              fi
              a=$(du -sm /var/cache/apt/archives 2>/dev/null | cut -f1)
              if command -v apt-get >/dev/null 2>&1 && [ "${a:-0}" -gt 500 ]; then
                if allowed "apt-get clean"; then sudo -n apt-get clean >/dev/null 2>&1; echo "@@fix aptcache $a"
                else echo "@@skipfix aptcache"; fi
              fi
            else
              j=$(du -sm /var/log/journal 2>/dev/null | cut -f1)
              [ "${j:-0}" -gt 1024 ] && echo "@@skipfix nosudo journal $j"
            fi
          fi
        fi
        } > "$BD/latest.new" 2>/dev/null
        [ -f "$BD/latest" ] && mv "$BD/latest" "$BD/previous"
        mv "$BD/latest.new" "$BD/latest"
        if [ -n "$BTOPIC" ]; then
          s=$(summary "$BD/latest"); att=$(printf '%s\n' "$s" | head -n 1); msg=$(printf '%s\n' "$s" | sed -n 2p)
          if [ "$att" = 1 ] || [ "$BQUIET" != 1 ]; then
            curl -fsS -m 15 -H "Title: Morning briefing · $BNAME" -H "Tags: $([ "$att" = 1 ] && echo warning || echo sunrise)" \
              -H "Click: deckhand://briefing" -d "$msg" "$BTOPIC" >/dev/null 2>&1
          fi
        fi
        true
        """#
    }

    /// Writes the config and the script and runs it every hour at the chosen minute (the script itself checks the
    /// hour in the user's time zone and runs once a day).
    public static func installCommand(_ c: Config) -> String {
        """
        command -v crontab >/dev/null 2>&1 || { echo '@@nocron'; exit 0; }
        mkdir -p \(dir) && chmod 700 \(dir)
        printf '%s\\n' \(ShellQuote.quote(c.file + "\nBMIN=\(c.minute)")) > \(dir)/config
        printf '%s\\n' \(ShellQuote.quote(script)) > \(dir)/run.sh && chmod 700 \(dir)/run.sh
        { crontab -l 2>/dev/null | grep -v 'deckhand/briefing/run.sh'; echo "\(c.minute) * * * * $HOME/.deckhand/briefing/run.sh >/dev/null 2>&1 \(cronTag)"; } | crontab -
        echo '@@ok'
        """
    }

    public static let uninstallCommand = """
    crontab -l 2>/dev/null | grep -v 'deckhand/briefing/run.sh' | crontab - 2>/dev/null; rm -rf "$HOME/.deckhand/briefing"; echo '@@ok'
    """

    /// Makes today's report now (no push when nothing needs attention and the briefing is quiet).
    public static let runNowCommand = "[ -x \(dir)/run.sh ] && FORCE=1 \(dir)/run.sh; echo '@@ok'"

    /// `@@installed`, `@@config <line>` per config line, then the latest report.
    public static let readCommand = """
    crontab -l 2>/dev/null | grep -q 'deckhand/briefing/run.sh' && echo '@@installed'
    [ -f \(dir)/config ] && sed 's/^/@@config /' \(dir)/config
    [ -f \(dir)/latest ] && cat \(dir)/latest
    true
    """

    // MARK: Report

    public struct Disk: Sendable, Hashable, Identifiable {
        public var mount: String
        public var used: Int
        public var availableKB: Int
        public var usedYesterday: Int?
        public var id: String { mount }
    }

    public enum Fix: Sendable, Hashable {
        case oldRuns(count: Int)
        case journal(beforeMB: Int, afterMB: Int)
        case packageCache(mb: Int)
    }

    public enum SkippedFix: Sendable, Hashable {
        case readOnly, journalForbidden, packageCacheForbidden
        case noSudo(journalMB: Int)
    }

    public struct Report: Sendable, Hashable {
        public var generated: Date
        public var host: String
        public var updates: UpdateStatus?
        public var expiry: Expiry.Status?
        public var cron: CronWatch.Status?
        public var disks: [Disk] = []
        public var memory: Double?
        /// Average memory use over the last 24 hours and the 24 before (needs the metrics history).
        public var memoryTrend: (last: Double, before: Double)?
        public var failedUnits: [String] = []
        /// nil when the server's logs can't be read without root.
        public var failedLogins: Int?
        public var fixes: [Fix] = []
        public var skipped: [SkippedFix] = []

        public static func == (a: Report, b: Report) -> Bool {
            a.generated == b.generated && a.host == b.host && a.disks == b.disks && a.memory == b.memory
                && a.memoryTrend?.last == b.memoryTrend?.last && a.memoryTrend?.before == b.memoryTrend?.before
                && a.failedUnits == b.failedUnits && a.failedLogins == b.failedLogins && a.fixes == b.fixes && a.skipped == b.skipped
                && a.updates == b.updates && a.expiry == b.expiry && a.cron == b.cron
        }
        public func hash(into h: inout Hasher) { h.combine(generated); h.combine(host) }
    }

    public struct State: Sendable, Hashable {
        public var installed = false
        public var config: Config?
        public var report: Report?
        public init() {}
    }

    public static func parse(_ out: String) -> State {
        var state = State()
        var configLines: [String] = []
        var sections: [String: [String]] = [:]
        var section = ""
        var report: Report?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == "@@installed" { state.installed = true; continue }
            if line.hasPrefix("@@config ") { configLines.append(String(line.dropFirst(9))); continue }
            if line.hasPrefix("@@briefing ") {
                let p = line.split(separator: " ", maxSplits: 2).map(String.init)
                report = Report(generated: Date(timeIntervalSince1970: Double(p.count > 1 ? p[1] : "") ?? 0), host: p.count > 2 ? p[2] : "")
                continue
            }
            if line.hasPrefix("@@section ") { section = String(line.dropFirst(10)); continue }
            guard report != nil else { continue }
            sections[section, default: []].append(line)
        }
        state.config = Config.parse(configLines)
        guard var r = report else { return state }
        if let u = sections["updates"] { r.updates = PackageUpdates.parse(u.joined(separator: "\n")) }
        if let e = sections["expiry"] { r.expiry = Expiry.parseStatus(e.joined(separator: "\n")) }
        if let c = sections["cron"] { r.cron = CronWatch.parseStatus(c.joined(separator: "\n")) }
        var yesterday: [String: Int] = [:]
        for line in (sections["system"] ?? []) + (sections["fixes"] ?? []) {
            let f = line.split(separator: " ").map(String.init)
            guard let tag = f.first else { continue }
            switch tag {
            case "@@disk" where f.count >= 4:
                if let used = Int(f[2]) { r.disks.append(Disk(mount: f[1], used: used, availableKB: Int(f[3]) ?? 0)) }
            case "@@prevdisk" where f.count >= 3:
                yesterday[f[1]] = Int(f[2])
            case "@@mem" where f.count >= 2:
                r.memory = Double(f[1])
            case "@@memtrend" where f.count >= 3:
                if let a = Double(f[1]), let b = Double(f[2]) { r.memoryTrend = (a, b) }
            case "@@failed" where f.count >= 2:
                r.failedUnits.append(f[1])
            case "@@logins" where f.count >= 2:
                r.failedLogins = Int(f[1])
            case "@@fix" where f.count >= 3:
                switch f[1] {
                case "runs": r.fixes.append(.oldRuns(count: Int(f[2]) ?? 0))
                case "journal": r.fixes.append(.journal(beforeMB: Int(f[2]) ?? 0, afterMB: Int(f.count > 3 ? f[3] : "") ?? 0))
                case "aptcache": r.fixes.append(.packageCache(mb: Int(f[2]) ?? 0))
                default: break
                }
            case "@@skipfix" where f.count >= 2:
                switch f[1] {
                case "readonly": r.skipped.append(.readOnly)
                case "journal": r.skipped.append(.journalForbidden)
                case "aptcache": r.skipped.append(.packageCacheForbidden)
                case "nosudo": r.skipped.append(.noSudo(journalMB: Int(f.count > 3 ? f[3] : "") ?? 0))
                default: break
                }
            default: break
            }
        }
        for i in r.disks.indices { r.disks[i].usedYesterday = yesterday[r.disks[i].mount] }
        state.report = r
        return state
    }

    // MARK: The briefing text

    public enum Level: Int, Sendable, Comparable {
        case attention, info, done
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Where an item leads in the app.
    public enum Tool: String, Sendable { case updates, expiry, disk, memory, services, cron, logins, rules }

    /// One line of the briefing, with its values (the app words it in the user's language).
    public enum Kind: Sendable, Hashable {
        case securityUpdates(Int), otherUpdates(Int), restartNeeded
        case certificateExpiring(domain: String, days: Int), domainExpiring(domain: String, days: Int)
        case diskFull(mount: String, used: Int, grewSinceYesterday: Int), diskGrew(mount: String, points: Int, used: Int)
        case memoryHigh(Int), memoryRising(from: Int, to: Int)
        case servicesFailed(Int)
        case cronFailed(String), cronLate(String)
        case failedLogins(Int)
        case removedOldRuns(Int), shrankJournal(fromMB: Int, toMB: Int), clearedPackages(mb: Int)
        case noFixesReadOnly, journalForbidden, packagesForbidden, journalNeedsSudo(mb: Int)
    }

    public struct Item: Sendable, Hashable, Identifiable {
        public var level: Level
        public var tool: Tool
        public var kind: Kind
        public var detail: String?
        public var id: String { "\(tool.rawValue):\(title)" }

        /// The line in English.
        public var title: String {
            func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
            func expires(_ d: Int) -> String { d < 0 ? "expired" : d == 0 ? "expires today" : "expires in \(plural(d, "day", "days"))" }
            switch kind {
            case .securityUpdates(let n): return plural(n, "security update", "security updates")
            case .otherUpdates(let n): return plural(n, "other update", "other updates")
            case .restartNeeded: return "Restart needed to finish updates"
            case .certificateExpiring(let d, let days): return "Certificate for \(d) \(expires(days))"
            case .domainExpiring(let d, let days): return "Domain \(d) \(expires(days))"
            case .diskFull(let m, let u, _): return "Disk \(m) is \(u)% full"
            case .diskGrew(let m, let p, let u): return "Disk \(m) grew \(p) points to \(u)%"
            case .memoryHigh(let u): return "Memory is \(u)% used"
            case .memoryRising(let a, let b): return "Memory use went up from \(a)% to \(b)% on average"
            case .servicesFailed(let n): return plural(n, "service failed", "services failed")
            case .cronFailed(let name): return "Cron job \(name) failed"
            case .cronLate(let name): return "Cron job \(name) didn't run on time"
            case .failedLogins(let n): return "\(plural(n, "failed login", "failed logins")) in 24 hours"
            case .removedOldRuns(let n): return "Removed \(plural(n, "old task log", "old task logs"))"
            case .shrankJournal(let a, let b): return "Shrank the system journal from \(a) MB to \(b) MB"
            case .clearedPackages(let mb): return "Cleared \(mb) MB of downloaded packages"
            case .noFixesReadOnly: return "No fixes: house rules are read-only"
            case .journalForbidden: return "Didn't shrink the journal: a house rule forbids it"
            case .packagesForbidden: return "Didn't clear the package cache: a house rule forbids it"
            case .journalNeedsSudo(let mb): return "The system journal uses \(mb) MB; shrinking it needs sudo without a password"
            }
        }
    }

    /// What the report says, most urgent first.
    public static func items(_ r: Report, now: Date = Date()) -> [Item] {
        var out: [Item] = []
        func days(_ d: Date?) -> Int? { d.map { Int(floor($0.timeIntervalSince(now) / 86_400)) } }
        func add(_ level: Level, _ tool: Tool, _ kind: Kind, _ detail: String? = nil) {
            out.append(Item(level: level, tool: tool, kind: kind, detail: detail))
        }

        if let u = r.updates {
            if !u.security.isEmpty { add(.attention, .updates, .securityUpdates(u.security.count), u.security.prefix(4).map(\.name).joined(separator: ", ")) }
            if !u.other.isEmpty { add(.info, .updates, .otherUpdates(u.other.count)) }
            if u.rebootRequired { add(.attention, .updates, .restartNeeded) }
        }
        for e in r.expiry?.entries ?? [] {
            if let d = days(e.certificateEnd), d <= 30 { add(d <= 14 ? .attention : .info, .expiry, .certificateExpiring(domain: e.domain, days: d)) }
            if let d = days(e.registrationEnd), d <= 30 { add(d <= 14 ? .attention : .info, .expiry, .domainExpiring(domain: e.domain, days: d)) }
        }
        for disk in r.disks {
            let grew = disk.usedYesterday.map { disk.used - $0 } ?? 0
            if disk.used >= 85 {
                add(.attention, .disk, .diskFull(mount: disk.mount, used: disk.used, grewSinceYesterday: max(0, grew)))
            } else if grew >= 5 {
                add(.info, .disk, .diskGrew(mount: disk.mount, points: grew, used: disk.used))
            }
        }
        if let m = r.memory, m >= 90 {
            add(.attention, .memory, .memoryHigh(Int(m)))
        } else if let t = r.memoryTrend, t.last - t.before >= 10 {
            add(.info, .memory, .memoryRising(from: Int(t.before), to: Int(t.last)))
        }
        if !r.failedUnits.isEmpty { add(.attention, .services, .servicesFailed(r.failedUnits.count), r.failedUnits.prefix(4).joined(separator: ", ")) }
        for w in (r.cron?.watches.values.sorted { $0.name < $1.name }) ?? [] {
            if let last = w.last, last.exitCode != 0 { add(.attention, .cron, .cronFailed(w.name), w.output.last) }
            else if w.missingSince != nil { add(.attention, .cron, .cronLate(w.name)) }
        }
        if let n = r.failedLogins, n > 0 { add(.info, .logins, .failedLogins(n)) }
        for f in r.fixes {
            switch f {
            case .oldRuns(let n): add(.done, .rules, .removedOldRuns(n))
            case .journal(let a, let b): add(.done, .rules, .shrankJournal(fromMB: a, toMB: b))
            case .packageCache(let mb): add(.done, .rules, .clearedPackages(mb: mb))
            }
        }
        for s in r.skipped {
            switch s {
            case .readOnly: add(.info, .rules, .noFixesReadOnly)
            case .journalForbidden: add(.info, .rules, .journalForbidden)
            case .packageCacheForbidden: add(.info, .rules, .packagesForbidden)
            case .noSudo(let mb): add(.info, .disk, .journalNeedsSudo(mb: mb))
            }
        }
        return out.enumerated().sorted { ($0.element.level, $0.offset) < ($1.element.level, $1.offset) }.map(\.element)
    }
}
