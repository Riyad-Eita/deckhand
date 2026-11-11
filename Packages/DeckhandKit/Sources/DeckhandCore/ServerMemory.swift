import Foundation

/// Notes the agents keep about one server (services, paths, quirks, decisions) in `~/.deckhand/memory.md`.
/// Every engine uses them: the own-key agent gets them as context plus a `remember` tool; Claude Code imports the
/// file from `~/.claude/CLAUDE.md`; Codex is told about it in `~/.codex/AGENTS.md`. You can read, edit and clear them.
public enum ServerMemory {
    public static let path = "~/.deckhand/memory.md"
    static let begin = "<!-- deckhand:memory -->"
    static let end = "<!-- /deckhand:memory -->"
    /// How much of the notes goes into a prompt.
    public static let promptLimit = 8_000

    public static let readCommand = "cat \(path) 2>/dev/null; true"

    /// Replaces the notes (sent base64-encoded, so any text is safe).
    public static func writeCommand(_ text: String) -> String {
        let b64 = Data(text.utf8).base64EncodedString()
        return "mkdir -p ~/.deckhand && chmod 700 ~/.deckhand && printf '%s' '\(b64)' | base64 -d > \(path) && chmod 600 \(path) && echo '@@ok'"
    }

    /// Adds one dated line.
    public static func appendCommand(_ note: String, date: Date = Date()) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        let line = "- \(note.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)) (\(day))"
        let b64 = Data((line + "\n").utf8).base64EncodedString()
        return "mkdir -p ~/.deckhand && chmod 700 ~/.deckhand && { [ -s \(path) ] || printf '# Server notes\\n\\n' > \(path); } && printf '%s' '\(b64)' | base64 -d >> \(path) && chmod 600 \(path) && echo '@@ok'"
    }

    public static let deleteCommand = "rm -f \(path) && echo '@@ok'"

    /// What the own-key agent gets in its system prompt.
    public static func promptSection(_ notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let intro = "Notes about this server from earlier sessions (\(path)). Use them, and call the `remember` tool when you learn something durable (where things live, how services run, decisions the user made). Keep notes short; never store secrets."
        guard !trimmed.isEmpty else { return intro + "\n(No notes yet.)" }
        let body = trimmed.count > promptLimit ? String(trimmed.suffix(promptLimit)) : trimmed
        return intro + "\n\n" + body
    }

    /// The managed block for Claude Code (`@` imports the file) and Codex (no imports: tells it where to look).
    static let claudeBlock = """
    \(begin)
    ## Server notes (kept with Deckhand)
    @\(path)

    When you learn something durable about this server (where things live, how services run, decisions the user made),
    add a short line to \(path). Never store secrets there.
    \(end)
    """

    static let codexBlock = """
    \(begin)
    ## Server notes (kept with Deckhand)
    Read \(path) at the start of a task: it has notes about this server from earlier sessions.
    When you learn something durable (where things live, how services run, decisions the user made), add a short line
    to that file. Never store secrets there.
    \(end)
    """

    /// Puts the blocks into the CLIs' global instruction files (only for CLIs that are installed), replacing old ones.
    public static var connectCLIsCommand: String {
        """
        dh_put() { f="$1"; mkdir -p "$(dirname "$f")"; touch "$f"
          awk -v b=\(ShellQuote.quote(begin)) -v e=\(ShellQuote.quote(end)) '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$f" > "$f.dh" && cat "$f.dh" > "$f" && rm -f "$f.dh"
          printf '\\n%s\\n' "$2" >> "$f"; }
        if command -v claude >/dev/null 2>&1 || [ -d ~/.claude ]; then dh_put ~/.claude/CLAUDE.md \(ShellQuote.quote(claudeBlock)); echo '@@claude'; fi
        if command -v codex >/dev/null 2>&1 || [ -d ~/.codex ]; then dh_put ~/.codex/AGENTS.md \(ShellQuote.quote(codexBlock)); echo '@@codex'; fi
        true
        """
    }

    /// Takes the blocks out again (when the notes are deleted).
    public static var disconnectCLIsCommand: String {
        """
        for f in ~/.claude/CLAUDE.md ~/.codex/AGENTS.md; do [ -f "$f" ] || continue
          awk -v b=\(ShellQuote.quote(begin)) -v e=\(ShellQuote.quote(end)) '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$f" > "$f.dh" && cat "$f.dh" > "$f" && rm -f "$f.dh"
        done; echo '@@ok'
        """
    }
}

/// `remember`: the own-key agent adds a line to the server notes.
struct RememberTool: AgentTool {
    /// Only writes the agent's own notes file: no approval needed.
    var isReadOnly: Bool { true }
    var spec: ToolSpec {
        ToolSpec(
            name: "remember",
            description: "Add a short durable note about this server to \(ServerMemory.path) (where things live, how services run, decisions the user made). Never store secrets.",
            inputSchema: [
                "type": "object",
                "properties": ["note": ["type": "string", "description": "One short sentence."]],
                "required": ["note"],
            ]
        )
    }

    func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String {
        let note = try input.requiredString("note")
        guard !note.trimmingCharacters(in: .whitespaces).isEmpty, note.count <= 500 else { throw ToolError.invalidInput("note must be 1–500 characters") }
        let r = try await shell.run(ServerMemory.appendCommand(note), timeout: .seconds(15))
        guard r.stdout.contains("@@ok") else { throw ToolError.failed(r.stderr) }
        return "Noted."
    }
}
