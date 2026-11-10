import Foundation

/// A command that keeps running on the server when the app or the connection goes away.
/// Output lines go to `~/.deckhand/runs/<id>.out`; the exit code lands in `<id>.exit` when it ends.
/// The app reads the file from any line onwards, so it can reattach after a dropped connection.
public struct DetachedRun: Sendable, Hashable, Codable {
    public let id: String

    public init(id: String = UUID().uuidString.lowercased()) { self.id = id }

    var base: String { "~/.deckhand/runs/\(id)" }

    /// Starts `command` in the background with a login shell; prints the PID.
    public func startCommand(_ command: String) -> String {
        """
        mkdir -p ~/.deckhand/runs; chmod 700 ~/.deckhand ~/.deckhand/runs
        S=; command -v setsid >/dev/null 2>&1 && S=setsid
        $S nohup bash -lc \(ShellQuote.quote(command + "; echo $? > \(base).exit")) > \(base).out 2> \(base).err < /dev/null &
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
        echo 143 > \(base).exit; echo stopped
        """
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
