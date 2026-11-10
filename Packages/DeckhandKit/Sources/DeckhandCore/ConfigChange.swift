import Foundation

/// A reversible change to system files. Before anything is touched, the files are copied into a dated backup
/// on the server; if applying, validating (e.g. `sshd -t`) or reloading fails, the old files come back at once.
/// Every change stays in the history with a diff and a one-tap rollback.
public struct ConfigChange: Sendable, Hashable {
    public var title: String
    /// Absolute paths of every file the change may create, edit or delete.
    public var files: [String]
    /// Bash run as root with `bash -e` (stops at the first failing command).
    public var apply: String
    /// Bash that must succeed after applying, e.g. `sshd -t`. Also run after a rollback.
    public var validate: String
    /// Bash that makes the change take effect, e.g. `systemctl reload ssh`. Also run after a rollback.
    public var reload: String
    /// Bash that must succeed once the change is live (e.g. sshd listens on the new port). Not run on rollback.
    public var verify: String
    /// If set, the server rolls the change back by itself after this many seconds unless the app confirms it
    /// (`confirmScript`) — protects against locking yourself out.
    public var guardSeconds: Int?

    public init(
        title: String, files: [String], apply: String, validate: String = "true", reload: String = "true",
        verify: String = "true", guardSeconds: Int? = nil
    ) {
        self.title = title
        self.files = files
        self.apply = apply
        self.validate = validate
        self.reload = reload
        self.verify = verify
        self.guardSeconds = guardSeconds
    }

    public static let defaultRoot = "/var/backups/deckhand"

    /// `20261110-101500-change-the-ssh-port`
    public static func makeID(title: String, date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { s, ch in if !(ch == "-" && s.hasSuffix("-")) { s.append(ch) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return stamp + "-" + String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The root script. Prints `@@step <name>` as it goes, `@@failed <step>` (after restoring) or `@@done`.
    public func script(id: String, root: String = ConfigChange.defaultRoot, date: Date = Date()) -> String {
        let b = ShellQuote.quote("\(root)/\(id)")
        let meta: JSONValue = ["title": .string(title), "created": .number(date.timeIntervalSince1970.rounded()),
                               "files": .array(files.map { .string($0) })]
        let list = files.map(ShellQuote.quote).joined(separator: " ")
        return """
        set -u
        R=\(ShellQuote.quote(root)); B=\(b)
        umask 022
        mkdir -p "$R" "$B/files" && chmod 755 "$R" "$B" && chmod 700 "$B/files" || { echo '@@failed backup'; exit 1; }
        printf '%s\\n' \(ShellQuote.quote(meta.jsonString())) > "$B/meta.json"
        printf '%s\\n' \(ShellQuote.quote(apply)) > "$B/apply.sh"
        printf '%s\\n' \(ShellQuote.quote(validate)) > "$B/validate.sh"
        printf '%s\\n' \(ShellQuote.quote(reload)) > "$B/reload.sh"
        printf '%s\\n' \(ShellQuote.quote(verify)) > "$B/verify.sh"
        printf '%s\\n' \(ShellQuote.quote(Self.rollbackScript(id: id, root: root))) > "$B/rollback.sh"
        : > "$B/files.txt"
        echo '@@step backup'
        for f in \(list); do
          echo "$f" >> "$B/files.txt"
          if [ -e "$f" ]; then mkdir -p "$B/files$(dirname "$f")" && cp -a "$f" "$B/files$f" || { echo '@@failed backup'; exit 1; }; fi
        done
        \(Self.restoreFunction)
        dh_fail() { echo "@@failed $1"; dh_restore; bash "$B/reload.sh" >/dev/null 2>&1; echo failed > "$B/status"; exit 1; }
        echo '@@step apply'
        # A separate process: `set -e` would be ignored in a subshell on the left of `||`.
        bash -e "$B/apply.sh" || dh_fail apply
        echo '@@step validate'
        bash "$B/validate.sh" || dh_fail validate
        echo '@@step reload'
        bash "$B/reload.sh" || dh_fail reload
        echo '@@step verify'
        bash "$B/verify.sh" || dh_fail verify
        \(guardLines)
        echo '@@done'
        """
    }

    private var guardLines: String {
        guard let guardSeconds else { return "echo applied > \"$B/status\"" }
        return """
        echo pending > "$B/status"
        S=; command -v setsid >/dev/null 2>&1 && S=setsid
        $S nohup bash -c 'sleep \(guardSeconds); [ -e "$1/confirmed" ] || DH_GUARD=1 bash "$1/rollback.sh"' dh-guard "$B" > "$B/guard.log" 2>&1 < /dev/null &
        echo $! > "$B/guard.pid"
        echo "@@guard \(guardSeconds)"
        """
    }

    /// Keeps a guarded change: stops the automatic rollback.
    public static func confirmScript(id: String, root: String = ConfigChange.defaultRoot) -> String {
        """
        B=\(ShellQuote.quote("\(root)/\(id)"))
        [ "$(cat "$B/status" 2>/dev/null)" = pending ] || { echo '@@failed not-pending'; exit 1; }
        touch "$B/confirmed"
        kill "$(cat "$B/guard.pid" 2>/dev/null)" 2>/dev/null
        rm -f "$B/guard.pid"
        echo applied > "$B/status"
        echo '@@done'
        """
    }

    /// Puts every file listed in `$B/files.txt` back as it was (files that didn't exist are removed).
    static let restoreFunction = #"""
    dh_restore() {
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -e "$B/files$f" ]; then mkdir -p "$(dirname "$f")"; cp -a "$B/files$f" "$f"; else rm -f "$f"; fi
      done < "$B/files.txt"
    }
    """#

    /// Restores the files of an earlier change, validates and reloads. Root script.
    public static func rollbackScript(id: String, root: String = ConfigChange.defaultRoot) -> String {
        """
        set -u
        B=\(ShellQuote.quote("\(root)/\(id)"))
        [ -f "$B/files.txt" ] || { echo '@@failed missing'; exit 1; }
        # A manual rollback also stops a pending automatic one.
        if [ -z "${DH_GUARD:-}" ] && [ -f "$B/guard.pid" ]; then touch "$B/confirmed"; kill "$(cat "$B/guard.pid")" 2>/dev/null; rm -f "$B/guard.pid"; fi
        \(restoreFunction)
        echo '@@step restore'
        dh_restore
        echo '@@step validate'
        bash "$B/validate.sh" || { echo '@@failed validate'; exit 1; }
        echo '@@step reload'
        bash "$B/reload.sh" || { echo '@@failed reload'; exit 1; }
        echo rolledback > "$B/status"
        echo '@@done'
        """
    }

    /// Unified diff between the backup and the files as they are now. Root script (backups are root-only).
    public static func diffScript(id: String, root: String = ConfigChange.defaultRoot) -> String {
        """
        B=\(ShellQuote.quote("\(root)/\(id)"))
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          old="$B/files$f"; [ -e "$old" ] || old=/dev/null
          new="$f"; [ -e "$new" ] || new=/dev/null
          diff -u --label "before: $f" --label "now: $f" "$old" "$new"
        done < "$B/files.txt"
        true
        """
    }

    // MARK: History

    public enum Status: String, Sendable, Hashable {
        case applied, failed, rolledback
        /// Live, but rolls back by itself unless confirmed.
        case pending
        /// Interrupted while running (e.g. the connection dropped mid-change).
        case unknown
    }

    public struct Record: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var created: Date
        public var files: [String]
        public var status: Status
    }

    /// Lists past changes. Readable without root: meta files are world-readable, the backed-up files are not.
    public static func listCommand(root: String = ConfigChange.defaultRoot) -> String {
        """
        for d in \(ShellQuote.quote(root))/*/; do
          [ -f "$d/meta.json" ] || continue
          echo "@@change $(basename "$d") $(cat "$d/status" 2>/dev/null || echo unknown)"
          head -n 1 "$d/meta.json"
        done
        true
        """
    }

    public static func parseList(_ output: String) -> [Record] {
        var records: [Record] = []
        var pending: (String, Status)?
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("@@change ") {
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 2 else { continue }
                pending = (parts[1], Status(rawValue: parts.count > 2 ? parts[2] : "") ?? .unknown)
            } else if let (id, status) = pending, let j = try? JSONValue.parse(line) {
                records.append(Record(
                    id: id, title: j["title"]?.stringValue ?? id,
                    created: Date(timeIntervalSince1970: j["created"]?.doubleValue ?? 0),
                    files: (j["files"]?.arrayValue ?? []).compactMap(\.stringValue), status: status))
                pending = nil
            }
        }
        return records.sorted { $0.created > $1.created }
    }

    // MARK: Progress

    /// What a change's output line means for the progress list.
    public enum Event: Equatable, Sendable {
        case step(String)
        case failed(String)
        /// The change is live but rolls back after this many seconds unless confirmed.
        case guarded(Int)
        case done
        case output(String)
    }

    public static func event(_ line: String) -> Event {
        if line == "@@done" { return .done }
        if line.hasPrefix("@@step ") { return .step(String(line.dropFirst(7))) }
        if line.hasPrefix("@@failed ") { return .failed(String(line.dropFirst(9))) }
        if line.hasPrefix("@@guard "), let s = Int(line.dropFirst(8)) { return .guarded(s) }
        return .output(line)
    }
}
