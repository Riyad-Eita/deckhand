import Foundation

/// A systemd service as listed by `systemctl`.
public struct ServiceUnit: Sendable, Hashable, Identifiable {
    public var name: String
    public var load: String
    public var active: String
    public var sub: String
    public var description: String
    public var id: String { name }

    public var isFailed: Bool { active == "failed" }
    public var isRunning: Bool { active == "active" && sub == "running" }
    public var isMissing: Bool { load == "not-found" }
    /// "nginx.service" → "nginx"
    public var shortName: String { name.hasSuffix(".service") ? String(name.dropLast(8)) : name }
}

public enum ServiceAction: String, Sendable, CaseIterable {
    case start, stop, restart, enable, disable

    public var title: String { rawValue.capitalized }
    /// Stopping or disabling can take a site offline.
    public var isDisruptive: Bool { self == .stop || self == .disable }
}

public enum ServiceError: Error, LocalizedError, Sendable, Equatable {
    /// The action needs root and the server asked for a password; run it in the terminal instead.
    case needsPassword(command: String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .needsPassword: "This needs your sudo password. Run it in the terminal to enter it."
        case .failed(let s): s
        }
    }
}

public enum Services {
    public static let listCommand = """
    systemctl list-units --type=service --all --no-pager -o json 2>/dev/null \
    || systemctl list-units --type=service --all --no-legend --no-pager --plain
    """

    /// Parses JSON (systemd ≥ 246) or the plain table. Missing units are dropped; failed first, then running, then by name.
    public static func parse(_ output: String) -> [ServiceUnit] {
        var units: [ServiceUnit] = []
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let json = try? JSONValue.parse(trimmed), let list = json.arrayValue {
            for u in list {
                guard let name = u["unit"]?.stringValue else { continue }
                units.append(ServiceUnit(
                    name: name, load: u["load"]?.stringValue ?? "", active: u["active"]?.stringValue ?? "",
                    sub: u["sub"]?.stringValue ?? "", description: u["description"]?.stringValue ?? ""))
            }
        } else {
            for line in trimmed.split(separator: "\n") {
                let p = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
                guard p.count >= 4, p[0].hasSuffix(".service") else { continue }
                units.append(ServiceUnit(name: p[0], load: p[1], active: p[2], sub: p[3], description: p.count > 4 ? p[4] : ""))
            }
        }
        return units.filter { !$0.isMissing }.sorted { a, b in
            func rank(_ u: ServiceUnit) -> Int { u.isFailed ? 0 : u.isRunning ? 1 : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.name < b.name
        }
    }

    /// Tries without a password; the caller maps "password is required" to `.needsPassword`.
    public static func actionCommand(_ action: ServiceAction, unit: String) -> String {
        "sudo -n systemctl \(action.rawValue) \(ShellQuote.quote(unit))"
    }

    /// What to type in the terminal when sudo needs a password.
    public static func terminalCommand(_ action: ServiceAction, unit: String) -> String {
        "sudo systemctl \(action.rawValue) \(ShellQuote.quote(unit)) && systemctl status --no-pager \(ShellQuote.quote(unit)) | head -5"
    }

    public static func check(_ result: CommandResult, action: ServiceAction, unit: String) throws {
        guard result.exitCode != 0 else { return }
        let err = result.stderr + result.stdout
        if err.contains("password is required") || err.contains("a terminal is required") {
            throw ServiceError.needsPassword(command: terminalCommand(action, unit: unit))
        }
        throw ServiceError.failed(err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "systemctl exited with \(result.exitCode)" : err)
    }

    public static func statusCommand(_ unit: String) -> String {
        "systemctl status --no-pager --lines=0 \(ShellQuote.quote(unit)) 2>&1 | head -12"
    }

    /// Recent logs; falls back to sudo -n when the user can't read the system journal.
    public static func logsCommand(_ unit: String, lines: Int = 150) -> String {
        let u = ShellQuote.quote(unit)
        return """
        out=$(journalctl -q -u \(u) -n \(lines) --no-pager -o short-iso 2>&1); \
        if [ -z "$(printf '%s' "$out" | grep -v '^-- No entries --$')" ]; then \
        sudo -n journalctl -q -u \(u) -n \(lines) --no-pager -o short-iso 2>/dev/null || echo '@@nojournal'; \
        else printf '%s\\n' "$out"; fi
        """
    }

    public static let noJournalHint = "No access to the system journal. Add your user to the 'adm' or 'systemd-journal' group (sudo usermod -aG adm $USER) to read service logs."
}
