import Foundation

/// A tool the agent can call. Tools run on the connected server through a `RemoteShell`.
public protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// Read-only tools can run without approval in the "auto-read" policy.
    var isReadOnly: Bool { get }
    func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String
}

public enum ToolError: Error, LocalizedError, Sendable {
    case invalidInput(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let s): "Invalid input: \(s)"
        case .failed(let s): s
        }
    }
}

extension JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let s = self[key]?.stringValue else { throw ToolError.invalidInput("missing string '\(key)'") }
        return s
    }
}

/// Keeps tool output inside a sane size for the model: head and tail with a marker in between.
func clip(_ text: String, limit: Int = 30_000) -> String {
    guard text.count > limit else { return text }
    let head = text.prefix(limit * 2 / 3)
    let tail = text.suffix(limit / 3)
    return "\(head)\n… [\(text.count - limit) characters omitted] …\n\(tail)"
}

public enum ServerTools {
    public static func all(workingDirectory: String) -> [any AgentTool] {
        [
            RunCommandTool(cwd: workingDirectory),
            ReadFileTool(cwd: workingDirectory),
            WriteFileTool(cwd: workingDirectory),
            EditFileTool(cwd: workingDirectory),
            ListDirectoryTool(cwd: workingDirectory),
            SearchTool(cwd: workingDirectory),
            RememberTool(),
        ]
    }

    static func resolve(_ path: String, cwd: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") { return path }
        return cwd.hasSuffix("/") ? cwd + path : cwd + "/" + path
    }

    /// `~/x` must stay unquoted for the shell to expand it.
    public static func shellPath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + ShellQuote.quote(String(path.dropFirst(2))) }
        return ShellQuote.quote(path)
    }

    public static func readFile(_ path: String, shell: any RemoteShell) async throws -> String {
        let r = try await shell.run("cat -- \(shellPath(path))", timeout: .seconds(30))
        guard r.exitCode == 0 else { throw ToolError.failed(r.stderr.isEmpty ? "cannot read \(path)" : r.stderr) }
        return r.stdout
    }

    public static func writeFile(_ path: String, content: String, shell: any RemoteShell) async throws {
        let b64 = Data(content.utf8).base64EncodedString()
        let p = shellPath(path)
        let cmd = "mkdir -p \"$(dirname -- \(p))\" && printf %s \(ShellQuote.quote(b64)) | base64 -d > \(p)"
        let r = try await shell.run(cmd, timeout: .seconds(60))
        guard r.exitCode == 0 else { throw ToolError.failed(r.stderr.isEmpty ? "cannot write \(path)" : r.stderr) }
    }
}

struct RunCommandTool: AgentTool {
    let cwd: String
    var isReadOnly: Bool { false }
    var spec: ToolSpec {
        ToolSpec(
            name: "run_command",
            description: """
            Run a shell command on the server (bash, non-interactive, no TTY) and return stdout, stderr and the \
            exit code. Runs in the workspace directory unless `cwd` is given. Do not start interactive programs \
            (vim, top, less); use flags like --yes / -y and pagers off. Long output is shortened.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The command line to run."],
                    "cwd": ["type": "string", "description": "Directory to run in (optional)."],
                    "timeout_seconds": ["type": "integer", "description": "Default 120, max 1800."],
                ],
                "required": ["command"],
            ]
        )
    }

    func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String {
        let command = try input.requiredString("command")
        let dir = input["cwd"]?.stringValue.map { ServerTools.resolve($0, cwd: cwd) } ?? cwd
        let seconds = min(max(input["timeout_seconds"]?.intValue ?? 120, 1), 1800)
        let wrapped = "cd \(ServerTools.shellPath(dir)) && { \(command)\n} < /dev/null"
        let r = try await shell.run(wrapped, timeout: .seconds(seconds))
        var out = "exit code: \(r.exitCode)\n"
        if !r.stdout.isEmpty { out += "stdout:\n\(clip(r.stdout))\n" }
        if !r.stderr.isEmpty { out += "stderr:\n\(clip(r.stderr, limit: 10_000))\n" }
        return out
    }
}

struct ReadFileTool: AgentTool {
    let cwd: String
    var isReadOnly: Bool { true }
    var spec: ToolSpec {
        ToolSpec(
            name: "read_file",
            description: "Read a text file on the server. Returns numbered lines. Use offset/limit for large files.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path, absolute or relative to the workspace."],
                    "offset": ["type": "integer", "description": "First line (1-based). Default 1."],
                    "limit": ["type": "integer", "description": "Number of lines. Default 2000."],
                ],
                "required": ["path"],
            ]
        )
    }

    func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String {
        let path = ServerTools.resolve(try input.requiredString("path"), cwd: cwd)
        let offset = max(input["offset"]?.intValue ?? 1, 1)
        let limit = min(max(input["limit"]?.intValue ?? 2000, 1), 5000)
        let cmd = "awk -v s=\(offset) -v e=\(offset + limit - 1) 'NR>=s && NR<=e {printf \"%6d\\t%s\\n\", NR, $0} NR>e {exit}' \(ServerTools.shellPath(path))"
        let r = try await shell.run(cmd, timeout: .seconds(30))
        guard r.exitCode == 0 else { throw ToolError.failed(r.stderr.isEmpty ? "cannot read \(path)" : r.stderr) }
        return r.stdout.isEmpty ? "(empty file or offset past the end)" : clip(r.stdout, limit: 60_000)
    }
}

struct WriteFileTool: AgentTool {
    let cwd: String
    var isReadOnly: Bool { false }
    var spec: ToolSpec {
        ToolSpec(
            name: "write_file",
            description: "Create or overwrite a file on the server with the given content. Creates parent folders.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "content": ["type": "string", "description": "Full file content."],
                ],
                "required": ["path", "content"],
            ]
        )
    }

    func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String {
        let path = ServerTools.resolve(try input.requiredString("path"), cwd: cwd)
        let content = try input.requiredString("content")
        try await ServerTools.writeFile(path, content: content, shell: shell)
        return "Wrote \(content.split(separator: "\n", omittingEmptySubsequences: false).count) lines to \(path)."
    }
}

struct EditFileTool: AgentTool {
    let cwd: String
    var isReadOnly: Bool { false }
    var spec: ToolSpec {
        ToolSpec(
            name: "edit_file",
            description: """
            Replace an exact string in a file on the server. `old_string` must match exactly once unless \
            `replace_all` is true. Read the file first.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "old_string": ["type": "string"],
                    "new_string": ["type": "string"],
                    "replace_all": ["type": "boolean"],
                ],
                "required": ["path", "old_string", "new_string"],
            ]
        )
    }

    func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String {
        let path = ServerTools.resolve(try input.requiredString("path"), cwd: cwd)
        let old = try input.requiredString("old_string")
        let new = try input.requiredString("new_string")
        let all = input["replace_all"]?.boolValue ?? false
        guard !old.isEmpty else { throw ToolError.invalidInput("old_string is empty") }
        let content = try await ServerTools.readFile(path, shell: shell)
        let count = content.components(separatedBy: old).count - 1
        guard count > 0 else { throw ToolError.failed("old_string not found in \(path)") }
        guard count == 1 || all else {
            throw ToolError.failed("old_string occurs \(count) times in \(path); add context or set replace_all")
        }
        let updated: String
        if all {
            updated = content.replacingOccurrences(of: old, with: new)
        } else {
            let range = content.range(of: old)!
            updated = content.replacingCharacters(in: range, with: new)
        }
        try await ServerTools.writeFile(path, content: updated, shell: shell)
        return "Edited \(path) (\(all ? count : 1) replacement\(all && count > 1 ? "s" : ""))."
    }
}

struct ListDirectoryTool: AgentTool {
    let cwd: String
    var isReadOnly: Bool { true }
    var spec: ToolSpec {
        ToolSpec(
            name: "list_directory",
            description: "List a directory on the server (ls -la). Defaults to the workspace directory.",
            inputSchema: [
                "type": "object",
                "properties": ["path": ["type": "string"]],
            ]
        )
    }

    func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String {
        let path = ServerTools.resolve(input["path"]?.stringValue ?? ".", cwd: cwd)
        let r = try await shell.run("ls -la -- \(ServerTools.shellPath(path))", timeout: .seconds(30))
        guard r.exitCode == 0 else { throw ToolError.failed(r.stderr) }
        return clip(r.stdout)
    }
}

struct SearchTool: AgentTool {
    let cwd: String
    var isReadOnly: Bool { true }
    var spec: ToolSpec {
        ToolSpec(
            name: "search",
            description: "Search file contents on the server with a regular expression (ripgrep, or grep -rn if missing).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string"],
                    "path": ["type": "string", "description": "Directory or file. Default: workspace."],
                    "glob": ["type": "string", "description": "Only files matching this glob, e.g. *.swift"],
                ],
                "required": ["pattern"],
            ]
        )
    }

    func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String {
        let pattern = ShellQuote.quote(try input.requiredString("pattern"))
        let path = ServerTools.shellPath(ServerTools.resolve(input["path"]?.stringValue ?? ".", cwd: cwd))
        let glob = input["glob"]?.stringValue
        let rgGlob = glob.map { " -g \(ShellQuote.quote($0))" } ?? ""
        let grepGlob = glob.map { " --include=\(ShellQuote.quote($0))" } ?? ""
        let cmd = """
        if command -v rg >/dev/null 2>&1; then rg -n --max-columns 300\(rgGlob) -e \(pattern) -- \(path) | head -500; \
        else grep -rnI --exclude-dir=.git --exclude-dir=node_modules\(grepGlob) -E -e \(pattern) -- \(path) | head -500; fi
        """
        let r = try await shell.run(cmd, timeout: .seconds(60))
        return r.stdout.isEmpty ? "No matches." : clip(r.stdout)
    }
}

/// Installs a public key for the current user on the server, idempotently and with safe permissions.
public enum KeyInstall {
    public static func command(publicKey: String) -> String {
        let key = ShellQuote.quote(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        return """
        umask 077; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys \
        && { grep -qxF \(key) ~/.ssh/authorized_keys || printf '%s\\n' \(key) >> ~/.ssh/authorized_keys; } && echo deckhand-key-ok
        """
    }

    public static func succeeded(_ result: CommandResult) -> Bool {
        result.exitCode == 0 && result.stdout.contains("deckhand-key-ok")
    }
}
