import Foundation

/// Claude Code and Codex sessions already on the server (started on a laptop, say): listed per folder, their
/// transcript read, and continued from the app with the CLI's resume.
public enum CLISessions {
    public struct Session: Sendable, Hashable, Identifiable {
        public var cli: ServerCLI
        public var id: String
        public var folder: String
        public var title: String
        public var modified: Date
        public init(cli: ServerCLI, id: String, folder: String, title: String, modified: Date) {
            self.cli = cli; self.id = id; self.folder = folder; self.title = title; self.modified = modified
        }
    }

    /// The newest sessions of both CLIs: one `@@session` line each with tab-separated cli, id, mtime, folder and a
    /// title (the session's title, else its first prompt). Only grep-sized pieces of each file are read.
    public static func listCommand(limit: Int = 40) -> String {
        #"""
        clean() { tr '\t\n' '  ' | cut -c1-200; }
        if [ -d ~/.claude/projects ]; then
          ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -n \#(limit) | while IFS= read -r f; do
            id=$(basename "$f" .jsonl)
            cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$f" | sed 's/^"cwd":"//; s/"$//')
            t=$(grep -o '"customTitle":"[^"]*"' "$f" | tail -1 | sed 's/^"customTitle":"//; s/"$//')
            [ -z "$t" ] && t=$(grep -m1 -o '"role":"user","content":"[^"]*' "$f" | sed 's/^"role":"user","content":"//')
            printf '@@session\tclaudeCode\t%s\t%s\t%s\t%s\n' "$id" "$(stat -c %Y "$f")" "$cwd" "$(printf %s "$t" | clean)"
          done
        fi
        if [ -d ~/.codex/sessions ]; then
          ls -t ~/.codex/sessions/*/*/*/*.jsonl 2>/dev/null | head -n \#(limit) | while IFS= read -r f; do
            meta=$(head -n 1 "$f" | head -c 20000)
            id=$(printf %s "$meta" | grep -o '"id":"[^"]*"' | head -1 | sed 's/^"id":"//; s/"$//')
            cwd=$(printf %s "$meta" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/^"cwd":"//; s/"$//')
            t=$(grep -o '"type":"input_text","text":"[^"]*' "$f" | sed 's/^"type":"input_text","text":"//' | grep -v '^[<#]' | head -1)
            [ -n "$id" ] && printf '@@session\tcodex\t%s\t%s\t%s\t%s\n' "$id" "$(stat -c %Y "$f")" "$cwd" "$(printf %s "$t" | clean)"
          done
        fi
        true
        """#
    }

    public static func parseList(_ out: String) -> [Session] {
        out.split(separator: "\n").compactMap { line -> Session? in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 6, p[0] == "@@session", let cli = ServerCLI(rawValue: p[1]), !p[2].isEmpty,
                  let epoch = Double(p[3]) else { return nil }
            let title = unescape(p[5]).trimmingCharacters(in: .whitespaces)
            return Session(cli: cli, id: p[2], folder: p[4].isEmpty ? "~" : unescape(p[4]),
                           title: title.isEmpty ? String(localized: "Untitled session") : title,
                           modified: Date(timeIntervalSince1970: epoch))
        }
        .sorted { $0.modified > $1.modified }
    }

    /// Sessions grouped by folder, the folder with the newest session first.
    public static func byFolder(_ sessions: [Session]) -> [(folder: String, sessions: [Session])] {
        Dictionary(grouping: sessions, by: \.folder)
            .map { ($0.key, $0.value.sorted { $0.modified > $1.modified }) }
            .sorted { ($0.1.first?.modified ?? .distantPast) > ($1.1.first?.modified ?? .distantPast) }
    }

    /// JSON string escapes as they appear in grep-extracted pieces.
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        if let decoded = try? JSONDecoder().decode(String.self, from: Data(("\"" + s + "\"").utf8)) { return decoded }
        return s.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// The conversation lines of a session (the last `lines` of them).
    public static func transcriptCommand(cli: ServerCLI, id: String, lines: Int = 600) -> String {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        switch cli {
        case .claudeCode:
            return "f=$(ls ~/.claude/projects/*/\(safe).jsonl 2>/dev/null | head -1); [ -n \"$f\" ] || { echo 'Session not found.' >&2; exit 1; }; "
                + "grep -E '\"type\":\"(user|assistant)\"' \"$f\" | tail -n \(lines)"
        case .codex:
            return "f=$(ls ~/.codex/sessions/*/*/*/*\(safe).jsonl 2>/dev/null | head -1); [ -n \"$f\" ] || { echo 'Session not found.' >&2; exit 1; }; "
                + "grep '\"type\":\"response_item\"' \"$f\" | tail -n \(lines)"
        }
    }

    /// The transcript as messages: what was said, tool calls and their results. Thinking and injected context are left out.
    public static func parseTranscript(cli: ServerCLI, _ out: String) -> [Message] {
        var messages: [Message] = []
        func add(_ role: Role, _ block: ContentBlock) {
            if let last = messages.last, last.role == role { messages[messages.count - 1].blocks.append(block) }
            else { messages.append(Message(role: role, blocks: [block], date: nil)) }
        }
        for line in out.split(separator: "\n") {
            guard let json = try? JSONValue.parse(String(line)) else { continue }
            switch cli {
            case .claudeCode:
                guard let m = json["message"], let role = m["role"]?.stringValue.flatMap(Role.init(rawValue:)) else { continue }
                if json["isSidechain"]?.boolValue == true { continue }
                if let text = m["content"]?.stringValue {
                    if role == .user && text.hasPrefix("<") { continue }
                    add(role, .text(text)); continue
                }
                for b in m["content"]?.arrayValue ?? [] {
                    switch b["type"]?.stringValue {
                    case "text":
                        if let t = b["text"]?.stringValue, !(role == .user && t.hasPrefix("<")) { add(role, .text(t)) }
                    case "tool_use":
                        add(.assistant, .toolUse(ToolCall(id: b["id"]?.stringValue ?? UUID().uuidString, name: claudeTool(b["name"]?.stringValue ?? "tool"),
                                                          input: claudeInput(b["input"] ?? .null))))
                    case "tool_result":
                        let content = b["content"]?.stringValue
                            ?? (b["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                        add(.user, .toolResult(ToolResult(toolUseID: b["tool_use_id"]?.stringValue ?? "", content: content,
                                                          isError: b["is_error"]?.boolValue ?? false)))
                    default: break
                    }
                }
            case .codex:
                guard let p = json["payload"] else { continue }
                switch p["type"]?.stringValue {
                case "message":
                    guard let role = p["role"]?.stringValue.flatMap(Role.init(rawValue:)) else { continue }
                    for c in p["content"]?.arrayValue ?? [] {
                        if let t = c["text"]?.stringValue, !t.hasPrefix("<"), !(role == .user && t.hasPrefix("# AGENTS.md")) { add(role, .text(t)) }
                    }
                case "function_call", "local_shell_call", "custom_tool_call":
                    let args = p["arguments"]?.stringValue.flatMap { try? JSONValue.parse($0) } ?? p["action"] ?? p["input"] ?? .null
                    add(.assistant, .toolUse(ToolCall(id: p["call_id"]?.stringValue ?? UUID().uuidString,
                                                      name: codexTool(p["name"]?.stringValue ?? "shell"), input: codexInput(args))))
                case "function_call_output", "local_shell_call_output", "custom_tool_call_output":
                    let out = p["output"]?.stringValue ?? p["output"]?["output"]?.stringValue ?? ""
                    add(.user, .toolResult(ToolResult(toolUseID: p["call_id"]?.stringValue ?? "", content: out)))
                default: break
                }
            }
        }
        return messages
    }

    /// Claude Code's Bash tool shows as a command card like the app's own runs.
    static func claudeTool(_ name: String) -> String { name == "Bash" ? "run_command" : name }
    static func claudeInput(_ input: JSONValue) -> JSONValue { input }

    static func codexTool(_ name: String) -> String { ["shell", "exec_command", "container.exec", "local_shell"].contains(name) ? "run_command" : name }
    /// Codex passes commands as argv arrays (`["bash", "-lc", "ls"]`): shown as one command line.
    static func codexInput(_ args: JSONValue) -> JSONValue {
        if let argv = args["command"]?.arrayValue?.compactMap(\.stringValue), !argv.isEmpty {
            let line = argv.count == 3 && ["bash", "sh", "zsh"].contains(argv[0]) && argv[1].hasPrefix("-") ? argv[2] : argv.joined(separator: " ")
            return ["command": .string(line)]
        }
        if let cmd = args["cmd"]?.stringValue { return ["command": .string(cmd)] }
        return args
    }
}
