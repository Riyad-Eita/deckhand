import Foundation

/// Heartbeats for cron jobs: a watched job runs through a small wrapper that records every run (start, end, exit
/// code, output tail); a check every 10 minutes pushes when a job hasn't run within its expected interval, and the
/// wrapper pushes when a run fails. Unwatching puts the original crontab line back exactly.
public enum CronWatch {
    static let dir = "$HOME/.deckhand/cronwatch"
    static let checkTag = "# deckhand-cronwatch-check"

    public struct Job: Sendable, Hashable, Identifiable {
        /// The crontab line as it is now.
        public var line: String
        public var schedule: String
        public var command: String
        /// Set when watched: the wrapper id.
        public var watchID: String?
        public var id: String { watchID ?? line }
    }

    /// Splits a crontab line into schedule and command; nil for comments and variable lines.
    public static func parseLine(_ line: String) -> (schedule: String, command: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
        if t.hasPrefix("@") {
            let p = t.split(separator: " ", maxSplits: 1).map(String.init)
            return p.count == 2 ? (p[0], p[1].trimmingCharacters(in: .whitespaces)) : nil
        }
        let p = t.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
        guard p.count == 6, p[0].range(of: #"^[0-9*/,\-]+$"#, options: .regularExpression) != nil else { return nil }
        return (p[0..<5].joined(separator: " "), p[5])
    }

    /// Roughly how often a schedule runs, in seconds (nil for @reboot).
    public static func interval(_ schedule: String) -> Int? {
        switch schedule {
        case "@reboot": return nil
        case "@hourly": return 3_600
        case "@daily", "@midnight": return 86_400
        case "@weekly": return 604_800
        case "@monthly": return 2_678_400
        case "@yearly", "@annually": return 31_622_400
        default: break
        }
        let f = schedule.split(separator: " ").map(String.init)
        guard f.count == 5 else { return nil }
        let (minute, hour, dom, dow) = (f[0], f[1], f[2], f[4])
        func every(_ field: String) -> Int? { field.hasPrefix("*/") ? Int(field.dropFirst(2)) : nil }
        if let n = every(minute), hour == "*" { return n * 60 }
        if minute == "*" { return 60 }
        if let n = every(hour) { return n * 3_600 }
        if hour == "*" { return 3_600 }
        if dom != "*" { return 2_678_400 }
        if dow != "*" {
            let days = dow.split(separator: ",").count
            return days >= 5 ? 86_400 * 3 : 604_800 / max(1, days)
        }
        if hour.contains(",") { return 86_400 / max(1, hour.split(separator: ",").count) }
        return 86_400
    }

    public static func describe(_ schedule: String) -> String {
        switch schedule {
        case "@reboot": return "At every boot"
        case "@hourly": return "Every hour"
        case "@daily", "@midnight": return "Every day"
        case "@weekly": return "Every week"
        case "@monthly": return "Every month"
        default: break
        }
        let f = schedule.split(separator: " ").map(String.init)
        guard f.count == 5 else { return schedule }
        if f[0].hasPrefix("*/"), f[1] == "*", f[2] == "*", f[3] == "*", f[4] == "*" { return "Every \(f[0].dropFirst(2)) minutes" }
        if f[0] == "*", f[1] == "*" { return "Every minute" }
        if let m = Int(f[0]), f[1] == "*" { return String(format: "Every hour at :%02d", m) }
        if let m = Int(f[0]), let h = Int(f[1]), f[2] == "*", f[3] == "*" {
            let time = String(format: "%02d:%02d", h, m)
            if f[4] == "*" { return "Every day at \(time)" }
            let names = ["0": "Sun", "1": "Mon", "2": "Tue", "3": "Wed", "4": "Thu", "5": "Fri", "6": "Sat", "7": "Sun"]
            let days = f[4].split(separator: ",").compactMap { names[String($0)] }
            if !days.isEmpty { return "\(days.joined(separator: ", ")) at \(time)" }
        }
        return schedule
    }

    /// Runs the watched command, records the run, pushes on failure (and when it works again).
    static let wrapper = #"""
    #!/bin/sh
    # Deckhand cron heartbeat: runs a watched job and records the run.
    D="${HOME:?}/.deckhand/cronwatch"; id="${1:?}"
    TOPIC=; [ -f "$D/config" ] && . "$D/config"
    start=$(date +%s); echo "$start" > "$D/$id.started"
    sh "$D/$id.cmd" > "$D/$id.out.new" 2>&1; ec=$?
    end=$(date +%s)
    tail -n 40 "$D/$id.out.new" > "$D/$id.out"; rm -f -- "${D:?}/${id:?}.out.new"
    echo "$start $end $ec" >> "$D/$id.runs"
    tail -n 200 "$D/$id.runs" > "$D/$id.tmp" && mv "$D/$id.tmp" "$D/$id.runs"
    name=$(cat "$D/$id.name" 2>/dev/null || echo "$id"); prev=$(cat "$D/$id.ok" 2>/dev/null || echo 0)
    if [ "$ec" = 0 ]; then
      echo 0 > "$D/$id.ok"; rm -f -- "${D:?}/${id:?}.missing"
      [ "$prev" != 0 ] && [ -n "$TOPIC" ] && curl -fsS -m 10 -H "Title: Deckhand cron" -H "Tags: white_check_mark" -d "Works again: $name" "$TOPIC" >/dev/null 2>&1
    else
      echo "$ec" > "$D/$id.ok"
      [ "$prev" = 0 ] && [ -n "$TOPIC" ] && curl -fsS -m 10 -H "Title: Deckhand cron" -H "Tags: rotating_light" -H "Priority: high" -d "Cron job failed (exit $ec): $name" "$TOPIC" >/dev/null 2>&1
    fi
    exit $ec
    """#

    /// Every 10 minutes: jobs whose last start is older than 1.5 × their interval + 10 minutes push once.
    static let checker = #"""
    #!/bin/sh
    D="${HOME:?}/.deckhand/cronwatch"; TOPIC=; [ -f "$D/config" ] && . "$D/config"
    now=$(date +%s)
    for f in "$D"/*.every; do [ -f "$f" ] || continue
      id=$(basename "$f" .every); every=$(cat "$f"); [ "$every" -gt 0 ] 2>/dev/null || continue
      last=$(cat "$D/$id.started" 2>/dev/null || cat "$D/$id.since" 2>/dev/null || echo "$now")
      [ $((now - last)) -gt $((every * 3 / 2 + 600)) ] || continue
      [ -f "$D/$id.missing" ] && continue
      echo "$now" > "$D/$id.missing"
      name=$(cat "$D/$id.name" 2>/dev/null || echo "$id")
      [ -n "$TOPIC" ] && curl -fsS -m 10 -H "Title: Deckhand cron" -H "Tags: warning" -H "Priority: high" -d "Cron job hasn't run: $name" "$TOPIC" >/dev/null 2>&1
    done
    true
    """#

    static func setup(topic: String) -> String {
        let t = topic.contains("'") ? "" : topic
        return """
        D=\(dir); mkdir -p "$D" && chmod 700 "$D"
        printf '%s\\n' \(ShellQuote.quote(wrapper)) > "$D/wrap.sh" && chmod 700 "$D/wrap.sh"
        printf '%s\\n' \(ShellQuote.quote(checker)) > "$D/check.sh" && chmod 700 "$D/check.sh"
        printf 'TOPIC=%s\\n' \(ShellQuote.quote(ShellQuote.quote(t))) > "$D/config"
        """
    }

    /// Wraps one crontab line (matched exactly). Its command moves to `<id>.cmd` (cron's `\%` becomes `%`); lines
    /// with an unescaped `%` (stdin for the job) aren't supported.
    public static func watchCommand(line: String, name: String, topic: String, id: String = String(UUID().uuidString.prefix(8)).lowercased()) -> String {
        guard let p = parseLine(line) else { return "echo '@@failed not a job line'" }
        if p.command.range(of: #"(^|[^\\])%"#, options: .regularExpression) != nil { return "echo '@@failed uses %'" }
        let id = id.filter { $0.isLetter || $0.isNumber }
        let cmd = p.command.replacingOccurrences(of: "\\%", with: "%")
        let every = interval(p.schedule) ?? 0
        let wrapped = "\(p.schedule) $HOME/.deckhand/cronwatch/wrap.sh \(id) # deckhand-cronwatch \(id)"
        return setup(topic: topic) + """

        printf '%s\\n' \(ShellQuote.quote(cmd)) > "$D/\(id).cmd"
        printf '%s\\n' \(ShellQuote.quote(line)) > "$D/\(id).line"
        printf '%s\\n' \(ShellQuote.quote(String(name.prefix(80)))) > "$D/\(id).name"
        echo \(every) > "$D/\(id).every"; date +%s > "$D/\(id).since"
        L=\(ShellQuote.quote(line))
        crontab -l 2>/dev/null > "$D/crontab.before"
        grep -qxF -- "$L" "$D/crontab.before" || { echo '@@failed line changed'; exit 0; }
        awk -v l="$L" -v w=\(ShellQuote.quote(wrapped)) 'done == 0 && $0 == l { print w; done = 1; next } { print }' "$D/crontab.before" | crontab -
        crontab -l 2>/dev/null | grep -q 'cronwatch/check.sh' || { crontab -l 2>/dev/null; echo "*/10 * * * * $HOME/.deckhand/cronwatch/check.sh >/dev/null 2>&1 \(checkTag)"; } | crontab -
        echo "@@watched \(id)"
        """
    }

    /// Puts the original line back and forgets the job's records.
    public static func unwatchCommand(id: String) -> String {
        let id = id.filter { $0.isLetter || $0.isNumber }
        guard !id.isEmpty else { return "echo '@@failed unknown'" }
        return """
        D=\(dir); [ -f "$D/\(id).line" ] || { echo '@@failed unknown'; exit 0; }
        L=$(cat "$D/\(id).line")
        crontab -l 2>/dev/null | awk -v tag='# deckhand-cronwatch \(id)' -v l="$L" 'index($0, tag) { print l; next } { print }' | crontab -
        for x in cmd line name every since started runs out ok missing tmp; do rm -f -- "${D:?}/\(id).$x"; done
        ls "$D"/*.line >/dev/null 2>&1 || crontab -l 2>/dev/null | grep -v 'cronwatch/check.sh' | crontab -
        echo '@@ok'
        """
    }

    /// The crontab's jobs and, for watched ones, their records. Lines: `@@job <line>`, `@@watch <id>\t<every>\t<name>`,
    /// `@@run <id> <start> <end> <exit>`, `@@out <id> <line>`, `@@missing <id> <epoch>`.
    public static let statusCommand = """
    D=\(dir)
    crontab -l 2>/dev/null | grep -v -e 'cronwatch/check.sh' -e '/\\.deckhand/[a-z]*/run\\.sh' | grep -vE '# deckhand-[a-z-]+$' | sed 's/^/@@job /'
    for f in "$D"/*.line; do [ -f "$f" ] || continue
      id=$(basename "$f" .line)
      printf '@@watch %s\\t%s\\t%s\\n' "$id" "$(cat "$D/$id.every" 2>/dev/null)" "$(cat "$D/$id.name" 2>/dev/null)"
      [ -f "$D/$id.runs" ] && tail -n 30 "$D/$id.runs" | sed "s/^/@@run $id /"
      [ -f "$D/$id.out" ] && tail -n 12 "$D/$id.out" | sed "s/^/@@out $id /"
      [ -f "$D/$id.missing" ] && echo "@@missing $id $(cat "$D/$id.missing")"
      echo "@@orig $id $(cat "$D/$id.line")"
    done
    true
    """

    public struct Run: Sendable, Hashable {
        public var start: Date
        public var end: Date
        public var exitCode: Int
        public var seconds: Int { Int(end.timeIntervalSince(start)) }
    }

    public struct Watch: Sendable, Hashable {
        public var id: String
        public var every: Int
        public var name: String
        public var runs: [Run] = []
        public var output: [String] = []
        public var missingSince: Date?
        /// The crontab line before it was wrapped.
        public var originalLine = ""
        public var originalCommand: String { CronWatch.parseLine(originalLine)?.command ?? originalLine }
        public var last: Run? { runs.last }
    }

    public struct Status: Sendable, Hashable {
        public var jobs: [Job] = []
        public var watches: [String: Watch] = [:]
    }

    public static func parseStatus(_ out: String) -> Status {
        var s = Status()
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("@@job ") {
                let line = String(raw.dropFirst(6))
                guard let p = parseLine(line) else { continue }
                let id = line.range(of: #"# deckhand-cronwatch ([a-z0-9]+)$"#, options: .regularExpression).map { String(line[$0].split(separator: " ").last!) }
                s.jobs.append(Job(line: line, schedule: p.schedule, command: p.command, watchID: id))
            } else if raw.hasPrefix("@@watch ") {
                let f = raw.dropFirst(8).components(separatedBy: "\t")
                guard f.count == 3 else { continue }
                s.watches[f[0]] = Watch(id: f[0], every: Int(f[1]) ?? 0, name: f[2])
            } else if raw.hasPrefix("@@run ") {
                let f = raw.dropFirst(6).split(separator: " ").map(String.init)
                guard f.count == 4, let a = Double(f[1]), let b = Double(f[2]), let c = Int(f[3]) else { continue }
                s.watches[f[0]]?.runs.append(Run(start: Date(timeIntervalSince1970: a), end: Date(timeIntervalSince1970: b), exitCode: c))
            } else if raw.hasPrefix("@@out ") {
                let rest = raw.dropFirst(6)
                guard let sp = rest.firstIndex(of: " ") else { continue }
                s.watches[String(rest[..<sp])]?.output.append(String(rest[rest.index(after: sp)...]))
            } else if raw.hasPrefix("@@orig ") {
                let rest = raw.dropFirst(7)
                guard let sp = rest.firstIndex(of: " ") else { continue }
                s.watches[String(rest[..<sp])]?.originalLine = String(rest[rest.index(after: sp)...])
            } else if raw.hasPrefix("@@missing ") {
                let f = raw.dropFirst(10).split(separator: " ")
                if f.count == 2, let t = Double(f[1]) { s.watches[String(f[0])]?.missingSince = Date(timeIntervalSince1970: t) }
            }
        }
        return s
    }
}
