import Foundation

/// Claude Code asks the phone before steps its permission mode doesn't allow by itself (`--permission-prompt-tool`).
/// The tool is a tiny MCP server on the server (Python, stdio): it writes the request next to the run, waits for the
/// app's answer and hands it to Claude Code. No answer in time means "deny", with a reason the model can read.
/// The run keeps going on the server, so the phone may be away: the request simply waits.
public enum PermissionPrompt {
    public static let toolName = "mcp__deckhand__approve"
    public static let scriptPath = "~/.deckhand/bin/deckhand-approve.py"
    /// How long a request waits for the phone.
    public static let timeoutSeconds = 900

    public struct Request: Sendable, Hashable, Identifiable {
        public var id: String
        public var tool: String
        public var input: JSONValue
        public var asked: Date
    }

    /// The MCP server. Requests are `<dir>/<n>.req` ({"id","tool","input","time"}), answers `<n>.res`
    /// ({"allow": bool, "message": str}), written by the app.
    public static let script = #"""
    import json, os, sys, time, uuid
    D = os.path.expanduser(sys.argv[1]); T = int(sys.argv[2]) if len(sys.argv) > 2 else 900
    os.makedirs(D, exist_ok=True)
    TOOL = {"name": "approve", "description": "Ask the user on their phone whether a tool call may run.",
            "inputSchema": {"type": "object", "properties": {"tool_name": {"type": "string"}, "input": {"type": "object"},
                            "tool_use_id": {"type": "string"}}, "required": ["tool_name", "input"]}}
    def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    def ask(a):
        rid = uuid.uuid4().hex[:12]; req = os.path.join(D, rid + ".req"); res = os.path.join(D, rid + ".res")
        tmp = req + ".tmp"
        with open(tmp, "w") as f: json.dump({"id": rid, "tool": a.get("tool_name", ""), "input": a.get("input", {}), "time": int(time.time())}, f)
        os.replace(tmp, req)
        end = time.time() + T
        while time.time() < end:
            if os.path.exists(res):
                try:
                    with open(res) as f: ans = json.load(f)
                except Exception: time.sleep(0.3); continue
                for p in (req, res):
                    try: os.remove(p)
                    except OSError: pass
                if ans.get("allow"): return {"behavior": "allow", "updatedInput": a.get("input", {})}
                return {"behavior": "deny", "message": ans.get("message") or "The user denied this step."}
            time.sleep(0.5)
        try: os.remove(req)
        except OSError: pass
        return {"behavior": "deny", "message": "No answer from the user's phone in %d minutes. Don't retry this step; say what you wanted to do and why, then stop." % (T // 60)}
    for line in sys.stdin:
        try: m = json.loads(line)
        except Exception: continue
        i, meth = m.get("id"), m.get("method")
        if i is None: continue
        if meth == "initialize":
            send({"jsonrpc": "2.0", "id": i, "result": {"protocolVersion": m.get("params", {}).get("protocolVersion", "2025-06-18"),
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "deckhand", "version": "1"}}})
        elif meth == "tools/list":
            send({"jsonrpc": "2.0", "id": i, "result": {"tools": [TOOL]}})
        elif meth == "tools/call":
            r = ask(m.get("params", {}).get("arguments", {}))
            send({"jsonrpc": "2.0", "id": i, "result": {"content": [{"type": "text", "text": json.dumps(r)}]}})
        else:
            send({"jsonrpc": "2.0", "id": i, "error": {"code": -32601, "message": "unknown method"}})
    """#

    /// The request as the chat shows it (like the tool cards of the run).
    public static func call(for r: Request) -> ToolCall {
        ClaudeCodeEventDecoder.normalize(id: "ask-" + r.id, name: r.tool, input: r.input)
    }

    /// Where a run's requests wait.
    public static func directory(for run: DetachedRun) -> String { run.base + ".ask" }

    /// Runs before the CLI: writes the MCP server and sets DH_CFG / DH_ASK (empty without python3 — the run then
    /// behaves as before: steps outside the permission mode are refused).
    public static func prefix(directory: String) -> String {
        // Claude Code starts the server without a shell: every path in the config must be absolute ($HOME expanded here).
        let dir = directory.hasPrefix("~/") ? "%s/" + directory.dropFirst(2) : directory
        let config = #"{"mcpServers":{"deckhand":{"command":"python3","args":["%s/.deckhand/bin/deckhand-approve.py","\#(dir)","\#(timeoutSeconds)"]}}}"#
        let homes = directory.hasPrefix("~/") ? #" "$HOME" "$HOME""# : #" "$HOME""#
        return installCommand + "; DH_CFG=\"$(printf \(ShellQuote.quote(config))\(homes))\"; DH_ASK=; command -v python3 >/dev/null 2>&1 && DH_ASK=1; "
    }

    /// Claude Code flags (after `prefix`): the permission prompt tool, only when python3 is there.
    public static let claudeFlags = #" ${DH_ASK:+--mcp-config "$DH_CFG" --permission-prompt-tool mcp__deckhand__approve}"#

    /// Writes the MCP server (runs before the CLI; cheap and idempotent).
    public static var installCommand: String {
        let b64 = Data(script.utf8).base64EncodedString()
        return "mkdir -p ~/.deckhand/bin && printf '%s' '\(b64)' | base64 -d > \(scriptPath)"
    }

    /// Lists open requests: "@@req <id>" then the request's JSON on the next line.
    public static func pendingCommand(directory: String) -> String {
        "for f in \(directory)/*.req; do [ -f \"$f\" ] || continue; r=\"${f%.req}.res\"; [ -e \"$r\" ] && continue; echo \"@@req $(basename \"$f\" .req)\"; cat \"$f\"; echo; done 2>/dev/null; true"
    }

    public static func parsePending(_ output: String) -> [Request] {
        var out: [Request] = []
        let lines = output.split(separator: "\n").map(String.init)
        var i = 0
        while i < lines.count {
            if lines[i].hasPrefix("@@req "), i + 1 < lines.count, let json = try? JSONValue.parse(lines[i + 1]),
               let id = json["id"]?.stringValue, isRequestID(id) {
                out.append(Request(id: id, tool: json["tool"]?.stringValue ?? "", input: json["input"] ?? .object([:]),
                                   asked: Date(timeIntervalSince1970: json["time"]?.doubleValue ?? 0)))
                i += 2
            } else { i += 1 }
        }
        return out.sorted { $0.asked < $1.asked }
    }

    static func isRequestID(_ s: String) -> Bool { !s.isEmpty && s.count <= 32 && s.allSatisfy { $0.isHexDigit } }

    /// The app's answer to one request.
    public static func answerCommand(directory: String, id: String, allow: Bool, message: String? = nil) -> String? {
        guard isRequestID(id) else { return nil }
        var answer: [String: JSONValue] = ["allow": .bool(allow)]
        if let message, !message.isEmpty { answer["message"] = .string(message) }
        let b64 = Data(JSONValue.object(answer).jsonString().utf8).base64EncodedString()
        let res = "\(directory)/\(id).res"
        return "printf '%s' '\(b64)' | base64 -d > \(res).tmp && mv \(res).tmp \(res)"
    }
}
