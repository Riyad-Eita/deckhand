import Foundation

/// Rules every agent must follow on one server ("never touch the database folder", "no restarts during business
/// hours"). Stored on the server in `~/.deckhand/rules/rules.json` and enforced there by one checker (`hook.py`):
/// Claude Code and Codex run it as a PreToolUse hook — also for tasks started from a laptop — and the own-key agent
/// asks it before every tool call. A blocked call names the rule and can be allowed once.
public struct HouseRules: Codable, Sendable, Equatable {
    /// Agents may look but not change anything: no file writes, only known read-only commands.
    public var readOnly = false
    /// Folders and files agents must leave alone (no edits, no shell commands that mention them).
    public var protectedPaths: [String] = []
    /// Commands (or command starts) that are never run, e.g. `docker system prune`.
    public var forbiddenCommands: [String] = []
    /// No `ufw allow`, `iptables … ACCEPT`, published Docker ports and the like.
    public var noOpenPorts = false
    /// No service restarts, stops or reboots in this window.
    public var quietHours: QuietHours?
    /// Spending cap per task in USD, enforced by Claude Code (`--max-budget-usd`).
    public var maxSpendUSD: Double?
    /// Ask on the phone's lock screen instead of just blocking (Claude Code and Codex runs).
    public var ask: Ask?

    /// Lock-screen approvals: a push with Allow / Deny (ntfy); risky commands open the app for Face ID.
    public struct Ask: Codable, Sendable, Equatable {
        /// The ntfy topic URL; answers come back on `<topic>-reply`.
        public var topic: String
        /// The app's id for this server (for the deep link).
        public var server: String
        /// How long a call waits for an answer before it is denied.
        public var minutes: Int
        public init(topic: String, server: String, minutes: Int = 10) { self.topic = topic; self.server = server; self.minutes = minutes }
        public var replyTopic: String { topic.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "-reply" }
    }

    public struct QuietHours: Codable, Sendable, Equatable {
        /// "HH:mm"
        public var start: String
        public var end: String
        /// ISO weekdays, 1 = Monday … 7 = Sunday.
        public var days: [Int]
        /// The window is in this time zone (the phone's when the rule was made), not the server's.
        public var timeZone: String

        public init(start: String = "09:00", end: String = "18:00", days: [Int] = [1, 2, 3, 4, 5], timeZone: String = TimeZone.current.identifier) {
            self.start = start
            self.end = end
            self.days = days
            self.timeZone = timeZone
        }
    }

    public init(
        readOnly: Bool = false, protectedPaths: [String] = [], forbiddenCommands: [String] = [], noOpenPorts: Bool = false,
        quietHours: QuietHours? = nil, maxSpendUSD: Double? = nil, ask: Ask? = nil
    ) {
        self.ask = ask
        self.readOnly = readOnly
        self.protectedPaths = protectedPaths
        self.forbiddenCommands = forbiddenCommands
        self.noOpenPorts = noOpenPorts
        self.quietHours = quietHours
        self.maxSpendUSD = maxSpendUSD
    }

    public var isEmpty: Bool {
        !readOnly && protectedPaths.isEmpty && forbiddenCommands.isEmpty && !noOpenPorts && quietHours == nil && maxSpendUSD == nil && ask == nil
    }

    /// Where databases usually keep their data — the "protect the database folder" preset.
    public static let databaseFolders = ["/var/lib/postgresql", "/var/lib/mysql", "/var/lib/mongodb", "/var/lib/redis"]

    // MARK: - On the server

    public static let directory = "~/.deckhand/rules"
    static let file = "~/.deckhand/rules/rules.json"

    public static let readCommand = "cat \(file) 2>/dev/null; true"

    /// Decodes what `readCommand` printed; nil when there are no rules (or the file can't be read).
    public static func decode(_ text: String) -> HouseRules? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let rules = try? JSONDecoder().decode(HouseRules.self, from: Data(trimmed.utf8)) else { return nil }
        return rules.isEmpty ? nil : rules
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data("{}".utf8), as: UTF8.self) + "\n"
    }

    /// Saves the rules and the checker, then hooks it into Claude Code and Codex (where installed).
    /// Prints `@@claude` / `@@codex` for each CLI it wired, `@@nopython` when python3 is missing, `@@ok` at the end.
    public func installCommand() -> String {
        let hook = Data(Self.hookScript.utf8).base64EncodedString()
        let json = Data(encoded().utf8).base64EncodedString()
        return """
        command -v python3 >/dev/null 2>&1 || { echo '@@nopython'; exit 0; }
        mkdir -p \(Self.directory) && chmod 700 ~/.deckhand \(Self.directory) && \
        printf '%s' '\(hook)' | base64 -d > \(Self.directory)/hook.py.dh && mv \(Self.directory)/hook.py.dh \(Self.directory)/hook.py && chmod 700 \(Self.directory)/hook.py && \
        printf '%s' '\(json)' | base64 -d > \(Self.file).dh && chmod 600 \(Self.file).dh && mv \(Self.file).dh \(Self.file) && \
        python3 \(Self.directory)/hook.py install
        """
    }

    /// Unhooks the checker from the CLIs and deletes the rules.
    public static let uninstallCommand = """
    if [ -f \(directory)/hook.py ] && command -v python3 >/dev/null 2>&1; then python3 \(directory)/hook.py uninstall >/dev/null; fi
    rm -rf \(directory) && echo '@@ok'
    """

    /// What the install printed.
    public struct InstallResult: Sendable, Equatable {
        public var ok: Bool
        public var noPython: Bool
        public var claudeCode: Bool
        public var codex: Bool
        public var errors: [String]

        public init(output: String) {
            let lines = output.split(separator: "\n").map(String.init)
            noPython = lines.contains("@@nopython")
            ok = !noPython && lines.contains("@@ok")
            claudeCode = lines.contains("@@claude")
            codex = lines.contains("@@codex")
            errors = lines.filter { $0.hasPrefix("@@error ") }.map { String($0.dropFirst(8)) }
        }
    }

    // MARK: - Checking a call of the own-key agent

    /// Asks the checker on the server about one own-key tool call. Prints a JSON verdict (nothing when no rules).
    public static func checkCommand(_ call: ToolCall, workingDirectory: String) -> String? {
        guard ["run_command", "write_file", "edit_file"].contains(call.name) else { return nil }
        let payload: JSONValue = ["tool_name": .string(call.name), "tool_input": call.input, "cwd": .string(workingDirectory)]
        let b64 = Data(payload.jsonString().utf8).base64EncodedString()
        return "[ -f \(directory)/hook.py ] || exit 0; printf '%s' '\(b64)' | base64 -d | python3 \(directory)/hook.py deckhand"
    }

    /// The rule a call breaks, from the checker's verdict.
    public struct Block: Sendable, Hashable {
        public var ruleID: String
        /// English title from the server; `HouseRules.title(for:)` gives a localized one.
        public var title: String
        /// Set for blocks reported by a server CLI: lets the user allow exactly this call once.
        public var fingerprint: String?

        public init(ruleID: String, title: String, fingerprint: String? = nil) {
            self.ruleID = ruleID
            self.title = title
            self.fingerprint = fingerprint
        }
    }

    public static func parseVerdict(_ stdout: String) -> Block? {
        guard let line = stdout.split(separator: "\n").last,
              let json = try? JSONValue.parse(String(line)),
              json["blocked"]?.boolValue == true,
              let rule = json["rule"]?.stringValue else { return nil }
        return Block(ruleID: rule, title: json["title"]?.stringValue ?? rule)
    }

    /// What the own-key agent tells the model when the user keeps a call blocked.
    public static func blockedMessage(_ block: Block) -> String {
        "Blocked by house rule: \(block.title). The server owner set this rule in Deckhand; don't try to get around it. Tell the user what you wanted to do."
    }

    /// Finds the checker's message in a tool result of Claude Code or Codex.
    public static func block(in text: String) -> Block? {
        guard let marker = text.range(of: #"\[deckhand-rule (\S+) ([0-9a-f]{12})\]"#, options: .regularExpression) else { return nil }
        let parts = text[marker].dropFirst(1).dropLast(1).split(separator: " ")
        guard parts.count == 3 else { return nil }
        var title = String(parts[1])
        if let t = text.range(of: #"Blocked by house rule: (.+?)\. The server owner"#, options: .regularExpression) {
            title = String(text[t].dropFirst("Blocked by house rule: ".count).dropLast(". The server owner".count))
        }
        return Block(ruleID: String(parts[1]), title: title, fingerprint: String(parts[2]))
    }

    /// The answer the app publishes after Face ID (`allow:<fingerprint>:<device>`).
    public static func answer(_ allow: Bool, fingerprint: String, device: String) -> String {
        "\(allow ? "allow" : "deny"):\(fingerprint):\(device.replacingOccurrences(of: ":", with: " "))"
    }

    /// Lets exactly the blocked call through once (within 15 minutes).
    public static func allowOnceCommand(_ fingerprint: String, now: Date = Date()) -> String? {
        guard fingerprint.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil else { return nil }
        let until = Int(now.timeIntervalSince1970) + 15 * 60
        return "mkdir -p \(directory) && echo '\(fingerprint) \(until)' >> \(directory)/allow && chmod 600 \(directory)/allow && echo '@@ok'"
    }

    // MARK: - Words

    /// A localized title for a rule id (`readOnly`, `path:0`, `command:1`, …), falling back to the server's text.
    public func title(for block: Block) -> String {
        let parts = block.ruleID.split(separator: ":")
        switch parts.first {
        case "readOnly": return String(localized: "Read-only mode: agents may look, not change")
        case "risky": return String(localized: "A command that can't easily be undone")
        case "noOpenPorts": return String(localized: "Never open ports")
        case "quietHours":
            if let q = quietHours { return String(localized: "No restarts \(q.start)–\(q.end)") }
        case "path":
            if parts.count == 2, let i = Int(parts[1]), protectedPaths.indices.contains(i) {
                return String(localized: "Hands off \(protectedPaths[i])")
            }
        case "command":
            if parts.count == 2, let i = Int(parts[1]), forbiddenCommands.indices.contains(i) {
                return String(localized: "Never run \(forbiddenCommands[i])")
            }
        default: break
        }
        return block.title
    }
}
