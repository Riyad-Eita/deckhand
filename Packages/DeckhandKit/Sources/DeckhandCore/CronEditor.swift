import Foundation

/// Scheduled jobs without cron syntax: a schedule builder that turns "every Monday at 3:00" into `0 3 * * 1` and
/// back, edits of the user's crontab by exact line, and the server's systemd timers with their last result.
public enum CronEditor {
    public enum Frequency: String, Sendable, CaseIterable, Identifiable {
        case minutes, hourly, daily, weekly, monthly, custom
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .minutes: "Every few minutes"
            case .hourly: "Every hour"
            case .daily: "Every day"
            case .weekly: "On certain weekdays"
            case .monthly: "Every month"
            case .custom: "Cron expression"
            }
        }
    }

    public struct Schedule: Sendable, Hashable {
        public var frequency: Frequency = .daily
        /// For `.minutes`: 1…30.
        public var everyMinutes = 15
        public var minute = 0
        public var hour = 3
        /// 0 = Sunday … 6 = Saturday.
        public var weekdays: Set<Int> = [1]
        public var dayOfMonth = 1
        public var expression = "0 3 * * *"
        public init() {}

        public var cron: String {
            switch frequency {
            case .minutes: return "*/\(max(1, min(everyMinutes, 59))) * * * *"
            case .hourly: return "\(minute) * * * *"
            case .daily: return "\(minute) \(hour) * * *"
            case .weekly: return "\(minute) \(hour) * * \(weekdays.isEmpty ? "1" : weekdays.sorted().map(String.init).joined(separator: ","))"
            case .monthly: return "\(minute) \(hour) \(max(1, min(dayOfMonth, 28))) * *"
            case .custom: return expression.trimmingCharacters(in: .whitespaces)
            }
        }

        /// The same schedule in plain words.
        public var description: String {
            let time = String(format: "%02d:%02d", hour, minute)
            switch frequency {
            case .minutes: return "Every \(everyMinutes) minutes"
            case .hourly: return String(format: "Every hour at :%02d", minute)
            case .daily: return "Every day at \(time)"
            case .weekly:
                let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                return "\(weekdays.sorted().map { names[$0] }.joined(separator: ", ")) at \(time)"
            case .monthly: return "On day \(dayOfMonth) of every month at \(time)"
            case .custom: return CronWatch.describe(expression)
            }
        }

        /// Reads a cron expression back into the builder (anything it can't show becomes `.custom`).
        public static func from(_ cron: String) -> Schedule {
            var s = Schedule()
            s.expression = cron
            let f = cron.split(separator: " ").map(String.init)
            guard f.count == 5 else { s.frequency = .custom; return s }
            if f[0].hasPrefix("*/"), let n = Int(f[0].dropFirst(2)), f[1...4].allSatisfy({ $0 == "*" }) {
                s.frequency = .minutes; s.everyMinutes = n; return s
            }
            guard let m = Int(f[0]), (0...59).contains(m) else { s.frequency = .custom; return s }
            s.minute = m
            if f[1] == "*", f[2] == "*", f[3] == "*", f[4] == "*" { s.frequency = .hourly; return s }
            guard let h = Int(f[1]), (0...23).contains(h), f[3] == "*" else { s.frequency = .custom; return s }
            s.hour = h
            if f[2] == "*", f[4] == "*" { s.frequency = .daily; return s }
            if f[2] == "*" {
                let days = f[4].split(separator: ",").compactMap { Int($0) }.map { $0 == 7 ? 0 : $0 }
                if !days.isEmpty, days.count == f[4].split(separator: ",").count, days.allSatisfy({ (0...6).contains($0) }) {
                    s.frequency = .weekly; s.weekdays = Set(days); return s
                }
            }
            if f[4] == "*", let d = Int(f[2]), (1...28).contains(d) { s.frequency = .monthly; s.dayOfMonth = d; return s }
            s.frequency = .custom
            return s
        }
    }

    /// Five fields with cron's characters, or an @ shortcut.
    public static func isValidExpression(_ e: String) -> Bool {
        let t = e.trimmingCharacters(in: .whitespaces)
        if ["@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@annually", "@reboot", "@midnight"].contains(t) { return true }
        let f = t.split(separator: " ")
        return f.count == 5 && f.allSatisfy { $0.range(of: #"^[0-9*/,\-]+$"#, options: .regularExpression) != nil }
    }

    // MARK: Crontab edits (exact lines)

    /// A job line; `%` in the command is escaped for cron.
    public static func line(schedule: String, command: String) -> String {
        "\(schedule) \(command.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "%", with: "\\%"))"
    }

    public static func addCommand(_ line: String) -> String {
        """
        L=\(ShellQuote.quote(line))
        { crontab -l 2>/dev/null; printf '%s\\n' "$L"; } | crontab - && echo '@@ok'
        """
    }

    /// Replaces (or with `new` nil removes) the first line equal to `old`; fails if it's gone.
    public static func replaceCommand(_ old: String, with new: String?) -> String {
        """
        O=\(ShellQuote.quote(old)); N=\(ShellQuote.quote(new ?? ""))
        T=$(crontab -l 2>/dev/null)
        printf '%s\\n' "$T" | grep -qxF -- "$O" || { echo '@@failed line changed'; exit 0; }
        printf '%s\\n' "$T" | awk -v o="$O" -v n="$N" -v drop=\(new == nil ? 1 : 0) 'done == 0 && $0 == o { done = 1; if (!drop) print n; next } { print }' | crontab - && echo '@@ok'
        """
    }

    // MARK: systemd timers

    /// `@@json <list-timers JSON>` (times in µs) and per timer
    /// `@@timer <unit>\t<description>\t<calendar>\t<service>\t<result>\t<exit status>`.
    public static let timersCommand = """
    command -v systemctl >/dev/null 2>&1 || exit 0
    echo "@@json $(systemctl list-timers --all --output=json --no-pager 2>/dev/null | tr -d '\\n')"
    systemctl list-units --type=timer --all --no-legend --plain 2>/dev/null | awk '{print $1}' | while read -r t; do
      [ -n "$t" ] || continue
      p=$(systemctl show "$t" -p Description -p TimersCalendar -p Unit 2>/dev/null)
      v() { printf '%s\\n' "$p" | sed -n "s/^$1=//p" | head -n 1; }
      cal=$(v TimersCalendar | sed -n 's/.*OnCalendar=\\([^;]*\\);.*/\\1/p' | sed 's/ *$//')
      u=$(v Unit); r=$(systemctl show "$u" -p Result --value 2>/dev/null); e=$(systemctl show "$u" -p ExecMainStatus --value 2>/dev/null)
      printf '@@timer %s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$t" "$(v Description)" "$cal" "$u" "$r" "$e"
    done
    true
    """

    public struct Timer: Sendable, Hashable, Identifiable {
        public var unit: String
        public var description: String
        public var calendar: String
        public var next: Date?
        public var last: Date?
        public var service: String
        public var result: String
        public var exitStatus: Int?
        public var id: String { unit }
        public var ok: Bool? { last == nil ? nil : result == "success" && (exitStatus ?? 0) == 0 }
    }

    public static func parseTimers(_ out: String) -> [Timer] {
        var times: [String: (next: Date?, last: Date?)] = [:]
        if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("@@json ") }),
           let list = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(7).utf8)) as? [[String: Any]] {
            func date(_ v: Any?) -> Date? {
                guard let us = (v as? NSNumber)?.doubleValue, us > 0 else { return nil }
                return Date(timeIntervalSince1970: us / 1_000_000)
            }
            for t in list { if let u = t["unit"] as? String { times[u] = (date(t["next"]), date(t["last"])) } }
        }
        return out.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("@@timer ") else { return nil }
            let f = line.dropFirst(8).components(separatedBy: "\t")
            guard f.count == 6 else { return nil }
            return Timer(unit: f[0], description: f[1], calendar: f[2], next: times[f[0]]?.next, last: times[f[0]]?.last,
                         service: f[3], result: f[4], exitStatus: Int(f[5]))
        }
        .sorted { ($0.next ?? .distantFuture) < ($1.next ?? .distantFuture) }
    }
}
