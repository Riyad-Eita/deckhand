import Foundation

/// A command that keeps running on the server when the app or the connection goes away.
/// Output lines go to `~/.deckhand/runs/<id>.out`; the exit code lands in `<id>.exit` when it ends.
/// The app reads the file from any line onwards, so it can reattach after a dropped connection.
public struct DetachedRun: Sendable, Hashable, Codable {
    public let id: String

    public init(id: String = UUID().uuidString.lowercased()) { self.id = id }

    public var base: String { "~/.deckhand/runs/\(id)" }

    /// Starts `command` in the background with a login shell; prints the PID.
    /// `meta` (one line of JSON) is stored next to the run so the job list can describe it.
    public func startCommand(_ command: String, meta: Meta? = nil, notify: Notify? = nil) -> String {
        let metaLine = meta.map { "printf '%s\\n' \(ShellQuote.quote($0.json)) > \(base).meta\n" } ?? ""
        let after = notify.map { "; " + $0.command(exitFile: "\(base).exit") } ?? ""
        return """
        mkdir -p ~/.deckhand/runs; chmod 700 ~/.deckhand ~/.deckhand/runs
        \(metaLine)        S=; command -v setsid >/dev/null 2>&1 && S=setsid
        $S nohup bash -lc \(ShellQuote.quote(command + "; echo $? > \(base).exit" + after)) > \(base).out 2> \(base).err < /dev/null &
        echo $! > \(base).pid
        echo started
        """
    }

    /// Streams the output from line `fromLine` (1-based) until the run has ended and everything is read.
    public func readCommand(fromLine: Int) -> String {
        let start = max(1, fromLine)
        return """
        f=\(base).out; [ -f "$f" ] || { echo '@@missing'; exit 0; }
        tail -n +\(start) -f "$f" & t=$!
        while [ ! -f \(base).exit ] && kill -0 "$(cat \(base).pid 2>/dev/null)" 2>/dev/null; do sleep 1; done
        sleep 1; kill $t 2>/dev/null; wait $t 2>/dev/null
        echo "@@exit $(cat \(base).exit 2>/dev/null || echo 143)"
        """
    }

    /// Whether the run is still going: prints running / ended.
    public var statusCommand: String {
        "if [ -f \(base).exit ]; then echo ended; elif kill -0 \"$(cat \(base).pid 2>/dev/null)\" 2>/dev/null; then echo running; else echo ended; fi"
    }

    /// Stops the run and everything it started.
    public var stopCommand: String {
        """
        p=$(cat \(base).pid 2>/dev/null)
        if [ -n "$p" ]; then
          kids=$(pgrep -P "$p" 2>/dev/null)
          kill -TERM -- "-$p" 2>/dev/null || { kill -TERM "$p" 2>/dev/null; [ -n "$kids" ] && kill -TERM $kids 2>/dev/null; }
        fi
        rm -f \(base).waiting; echo 143 > \(base).exit; echo stopped
        """
    }

    /// A push to an ntfy topic when the run ends (not when it was stopped) — real notifications without our own backend.
    public struct Notify: Sendable, Hashable {
        /// The full topic URL, e.g. `https://ntfy.sh/deckhand-abc123`.
        public var topicURL: String
        public var doneMessage: String
        public var failedMessage: String
        /// Opened when the notification is tapped, e.g. `deckhand://thread/<id>`.
        public var click: String?

        public init(topicURL: String, doneMessage: String, failedMessage: String, click: String? = nil) {
            self.topicURL = topicURL
            self.doneMessage = doneMessage
            self.failedMessage = failedMessage
            self.click = click
        }

        func command(exitFile: String) -> String {
            let click = self.click.map { " -H \(ShellQuote.quote("Click: " + $0))" } ?? ""
            return """
            c=$(cat \(exitFile) 2>/dev/null); if [ "$c" != 143 ]; then if [ "$c" = 0 ]; then m=\(ShellQuote.quote(doneMessage)); t=white_check_mark; else m=\(ShellQuote.quote(failedMessage)); t=warning; fi; \
            curl -fsS -m 15 -H 'Title: Deckhand' -H "Tags: $t"\(click) -d "$m" \(ShellQuote.quote(topicURL)) >/dev/null 2>&1; fi
            """
        }
    }

    /// Removes a run's files from the server.
    public var deleteCommand: String { "rm -f \(base).out \(base).err \(base).pid \(base).exit \(base).meta \(base).waiting" }

    /// What a run is about, stored as `<id>.meta`.
    public struct Meta: Sendable, Hashable, Codable {
        public var title: String
        public var engine: String
        public var directory: String
        public var started: Date
        public init(title: String, engine: String, directory: String, started: Date = Date()) {
            self.title = title; self.engine = engine; self.directory = directory; self.started = started
        }
        var json: String {
            let obj: JSONValue = ["title": .string(title), "engine": .string(engine), "directory": .string(directory),
                                  "started": .number(started.timeIntervalSince1970.rounded())]
            return obj.jsonString()
        }
        init?(json line: String) {
            guard let j = try? JSONValue.parse(line), let title = j["title"]?.stringValue else { return nil }
            self.title = title
            engine = j["engine"]?.stringValue ?? ""
            directory = j["directory"]?.stringValue ?? "~"
            started = Date(timeIntervalSince1970: j["started"]?.doubleValue ?? 0)
        }
    }

    public enum Status: Sendable, Hashable {
        case running
        /// Paused by a usage limit until the given time, then it continues by itself.
        case waiting(until: Date)
        case ended(exitCode: Int32)

        public var isActive: Bool { if case .ended = self { false } else { true } }
    }

    /// A run found on the server.
    public struct Info: Sendable, Hashable, Identifiable {
        public var run: DetachedRun
        public var status: Status
        public var meta: Meta?
        public var id: String { run.id }
    }

    /// Lists every run that has a `.meta` file: one `@@run <id> <status…>` line, then the meta line.
    public static let listCommand = """
    cd ~/.deckhand/runs 2>/dev/null || exit 0
    for m in *.meta; do
      [ -f "$m" ] || continue; id=${m%.meta}
      if [ -f "$id.exit" ]; then st="ended $(cat "$id.exit")"
      elif kill -0 "$(cat "$id.pid" 2>/dev/null)" 2>/dev/null; then
        if [ -f "$id.waiting" ]; then st="waiting $(cat "$id.waiting")"; else st=running; fi
      else st="ended 137"; fi
      echo "@@run $id $st"; head -n 1 "$m"
    done
    """

    public static func parseList(_ output: String) -> [Info] {
        var result: [Info] = []
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("@@run ") {
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 3 else { continue }
                let status: Status = switch parts[2] {
                case "running": .running
                case "waiting": .waiting(until: Date(timeIntervalSince1970: Double(parts.count > 3 ? parts[3] : "") ?? 0))
                default: .ended(exitCode: Int32(parts.count > 3 ? parts[3] : "") ?? 1)
                }
                result.append(Info(run: DetachedRun(id: parts[1]), status: status, meta: nil))
            } else if !result.isEmpty, result[result.count - 1].meta == nil {
                result[result.count - 1].meta = Meta(json: line)
            }
        }
        return result.sorted { ($0.meta?.started ?? .distantPast) > ($1.meta?.started ?? .distantPast) }
    }

    /// Lines the reader prints besides the run's own output.
    public enum Marker: Equatable {
        case exit(Int32)
        case missing
    }

    public static func marker(_ line: String) -> Marker? {
        if line == "@@missing" { return .missing }
        if line.hasPrefix("@@exit ") { return .exit(Int32(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 1) }
        return nil
    }
}
