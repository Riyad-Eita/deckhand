import Foundation

/// How much of the Claude and ChatGPT plans is left, as far as the server CLIs tell: Codex records its 5-hour and
/// weekly usage in its session files; Claude Code only says so when a limit is hit.
public enum PlanUsage {
    public struct Window: Sendable, Hashable {
        public var minutes: Int
        public var usedPercent: Double
        public var resetsAt: Date?
        public var name: String {
            switch minutes {
            case 300: String(localized: "5-hour")
            case 10080: String(localized: "Weekly")
            default: minutes % 1440 == 0 ? String(localized: "\(minutes / 1440)-day") : String(localized: "\(minutes / 60)-hour")
            }
        }
    }

    public struct Usage: Sendable, Hashable {
        public var cli: ServerCLI
        /// When the CLI last reported it.
        public var seen: Date
        public var windows: [Window] = []
        /// The last limit message and when that limit resets (Claude Code).
        public var limitMessage: String?
        public var limitResets: Date?
    }

    /// Not root. `@@codex <epoch>\t<last token_count line>` and `@@claude <epoch>\t<last limit message>`, from the newest
    /// session files.
    public static let statusCommand = #"""
    f=$(ls -t ~/.codex/sessions/*/*/*/*.jsonl 2>/dev/null | head -n 1)
    if [ -n "$f" ]; then
      l=$(grep '"rate_limits"' "$f" | tail -n 1 | head -c 20000)
      [ -n "$l" ] && printf '@@codex\t%s\t%s\n' "$(stat -c %Y "$f")" "$l"
    fi
    for f in $(ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -n 5); do
      m=$(grep -oE "(You've hit your|You have hit your|Claude AI usage limit reached)[^\"]{0,160}" "$f" | tail -n 1)
      if [ -n "$m" ]; then printf '@@claude\t%s\t%s\n' "$(stat -c %Y "$f")" "$m"; break; fi
    done
    true
    """#

    public static func parse(_ out: String, now: Date = Date()) -> [Usage] {
        var result: [Usage] = []
        for line in out.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard p.count == 3, let epoch = Double(p[1]) else { continue }
            let seen = Date(timeIntervalSince1970: epoch)
            if p[0] == "@@codex", let json = try? JSONValue.parse(p[2]), let limits = json["payload"]?["rate_limits"] {
                var u = Usage(cli: .codex, seen: seen)
                for key in ["primary", "secondary"] {
                    guard let w = limits[key], let used = w["used_percent"]?.doubleValue, let minutes = w["window_minutes"]?.intValue else { continue }
                    let resets = w["resets_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
                        ?? w["resets_in_seconds"]?.doubleValue.map { seen.addingTimeInterval($0) }
                    // A window that has reset since counts as unused.
                    let stale = resets.map { $0 <= now } ?? false
                    u.windows.append(Window(minutes: minutes, usedPercent: stale ? 0 : used, resetsAt: stale ? nil : resets))
                }
                result.append(u)
            } else if p[0] == "@@claude" {
                let resets = resetTime(in: p[2], after: seen)
                // Only a limit that hasn't reset yet matters.
                if let resets, resets <= now { continue }
                result.append(Usage(cli: .claudeCode, seen: seen, limitMessage: p[2], limitResets: resets))
            }
        }
        return result
    }

    /// "resets 2:50am (Europe/Berlin)" or "resets Nov 12, 3pm (Europe/Berlin)": the next such moment after `after`.
    public static func resetTime(in text: String, after: Date) -> Date? {
        let pattern = #"resets (?:at )?(?:([A-Z][a-z]{2}) (\d{1,2}),? )?(\d{1,2})(?::(\d{2}))? ?(am|pm)(?: \(([A-Za-z_]+/[A-Za-z_/]+)\))?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
        guard var hour = group(3).flatMap(Int.init) else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        let pm = group(5)?.lowercased() == "pm"
        if hour == 12 { hour = pm ? 12 : 0 } else if pm { hour += 12 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = group(6).flatMap(TimeZone.init(identifier:)) ?? .current
        if let monthName = group(1), let day = group(2).flatMap(Int.init) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = months.firstIndex(of: monthName.lowercased()).map({ $0 + 1 }) else { return nil }
            var c = cal.dateComponents([.year], from: after)
            c.month = month; c.day = day; c.hour = hour; c.minute = minute
            guard var d = cal.date(from: c) else { return nil }
            if d < after.addingTimeInterval(-86400) { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
            return d
        }
        return cal.nextDate(after: after, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
    }

    /// A gentle warning before starting a task, from 80 % of a window used (or a limit that hasn't reset).
    public static func warning(_ usage: Usage?, now: Date = Date()) -> (text: String, resetsAt: Date?)? {
        guard let usage else { return nil }
        if let resets = usage.limitResets, resets > now {
            return (String(localized: "\(usage.cli.displayName) hit its usage limit; it resets \(resets.formatted(date: .omitted, time: .shortened))."), resets)
        }
        guard let w = usage.windows.filter({ $0.usedPercent >= 80 }).max(by: { $0.usedPercent < $1.usedPercent }) else { return nil }
        let when = w.resetsAt.map { " " + String(localized: "Resets \($0.formatted(date: w.minutes > 1440 ? .abbreviated : .omitted, time: .shortened)).") } ?? ""
        return (String(localized: "\(Int(w.usedPercent.rounded())) % of the \(w.name) limit used.") + when, w.resetsAt)
    }
}
