import Foundation

/// Where log lines come from.
public enum LogSource: Sendable, Hashable, Identifiable {
    case journal(unit: String?)
    case file(path: String, size: Int64)

    public var id: String {
        switch self {
        case .journal(let u): "journal:\(u ?? "*")"
        case .file(let p, _): "file:\(p)"
        }
    }

    public var title: String {
        switch self {
        case .journal(let u): u.map { "Journal · \($0)" } ?? "System journal"
        case .file(let p, _): (p as NSString).lastPathComponent
        }
    }

    public var subtitle: String {
        switch self {
        case .journal: "journalctl"
        case .file(let p, let size): "\(p) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
        }
    }
}

public enum LogLevel: Int, Sendable, Comparable {
    case info = 0, warning = 1, error = 2
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct LogLine: Sendable, Hashable, Identifiable {
    public let id: Int
    public let text: String
    public let level: LogLevel

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
        self.level = Logs.level(of: text)
    }
}

public enum Logs {
    /// Readable log files under /var/log and the home folder, newest first, plus the journal.
    public static let discoverCommand = """
    command -v journalctl >/dev/null 2>&1 && echo '@@journal'
    { find /var/log -maxdepth 3 -type f -readable \\( -name '*.log' -o -name syslog -o -name messages -o -name '*.err' -o -name '*.out' \\) -size +0 -printf '%T@ %s %p\\n' 2>/dev/null
      find ~ -maxdepth 4 -type f -readable -name '*.log' -size +0 -not -path '*/node_modules/*' -not -path '*/.cache/*' -not -path '*/.vscode-server*' -printf '%T@ %s %p\\n' 2>/dev/null
    } | sort -rn | head -60
    """

    public static func parseSources(_ output: String) -> [LogSource] {
        var sources: [LogSource] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n") {
            if line == "@@journal" { sources.insert(.journal(unit: nil), at: 0); continue }
            let p = line.split(separator: " ", maxSplits: 2)
            guard p.count == 3, let size = Int64(p[1]) else { continue }
            let path = String(p[2])
            if seen.insert(path).inserted { sources.append(.file(path: path, size: size)) }
        }
        return sources
    }

    public static func readCommand(_ source: LogSource, lines: Int = 400, errorsOnly: Bool = false) -> String {
        switch source {
        case .journal(let unit):
            let u = unit.map { " -u \(ShellQuote.quote($0))" } ?? ""
            let p = errorsOnly ? " -p warning" : ""
            return "journalctl -q --no-pager -o short-iso -n \(lines)\(u)\(p) 2>&1 | tail -n \(lines)"
        case .file(let path, _):
            let tail = "tail -n \(errorsOnly ? lines * 10 : lines) \(ShellQuote.quote(path))"
            return errorsOnly ? "\(tail) | grep -iE 'error|err\\]|fatal|crit|panic|exception|fail|warn' | tail -n \(lines)" : tail
        }
    }

    /// Follows new lines; bounded so nothing keeps running on the server if the app disappears.
    public static func followCommand(_ source: LogSource, seconds: Int = 600) -> String {
        switch source {
        case .journal(let unit):
            let u = unit.map { " -u \(ShellQuote.quote($0))" } ?? ""
            return "timeout \(seconds) journalctl -q --no-pager -o short-iso -f -n 0\(u) || true"
        case .file(let path, _):
            return "timeout \(seconds) tail -n 0 -F \(ShellQuote.quote(path)) 2>/dev/null || true"
        }
    }

    public static func level(of line: String) -> LogLevel {
        let l = line.lowercased()
        if l.range(of: #"\b(error|err|fatal|crit(ical)?|panic|emerg|alert|exception|traceback|failed)\b"#, options: .regularExpression) != nil {
            return .error
        }
        if l.range(of: #"\b(warn(ing)?|deprecated|timeout|slow|retry(ing)?)\b"#, options: .regularExpression) != nil {
            return .warning
        }
        return .info
    }

    public static let journalHint = "Only your own journal entries are visible. Add your user to the 'adm' or 'systemd-journal' group (sudo usermod -aG adm $USER) to read system logs."

    /// Prompt for the agent from the selected or most recent problem lines.
    public static func explainPrompt(source: LogSource, lines: [LogLine]) -> String {
        let picked = lines.filter { $0.level >= .warning }.suffix(25).map(\.text)
        let sample = (picked.isEmpty ? lines.suffix(25).map(\.text) : picked).joined(separator: "\n")
        return """
        These lines are from \(source.subtitle) on this server. Explain in plain words what is going wrong, find the cause \
        (look at the related config and logs on the server), and suggest a fix. Don't change anything yet — ask me first.

        ```
        \(sample)
        ```
        """
    }
}
