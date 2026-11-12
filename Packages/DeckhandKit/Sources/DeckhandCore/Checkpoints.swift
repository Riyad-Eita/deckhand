import Foundation

/// Every file an agent changed during a task, with diffs and undo — for any engine and with or without a Git repo in
/// the folder. Before each turn the app snapshots the working folder into a private shadow repository
/// (`~/.deckhand/checkpoints/<task>`, never the project's own `.git`); the first snapshot is the task's starting point.
public enum Checkpoints {
    static let root = "$HOME/.deckhand/checkpoints"
    /// Above this many files the folder isn't snapshotted (a home folder, a whole disk).
    static let maxFiles = 20_000

    /// Every command `cd`s into the folder first, so the work tree is `.` (a `~` after `=` wouldn't be expanded).
    static func git(_ id: String, _ dir: String) -> String {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "git --git-dir=\"\(root)/\(safe)\" --work-tree=. -c user.name=Deckhand -c user.email=deckhand@localhost -c core.quotepath=false"
    }

    /// Records the folder now. Prints `@@checkpoint <sha>`, `@@unchanged <sha>`, `@@toobig <n>` or `@@nogit`.
    public static func createCommand(task id: String, folder dir: String) -> String {
        let g = git(id, dir)
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return """
        command -v git >/dev/null 2>&1 || { echo '@@nogit'; exit 0; }
        cd \(ServerTools.shellPath(dir)) 2>/dev/null || { echo '@@missing'; exit 0; }
        n=$(find . -path ./.git -prune -o -path ./node_modules -prune -o -path ./.venv -prune -o -type f -print 2>/dev/null | head -n \(maxFiles + 1) | wc -l | tr -d ' ')
        [ "$n" -gt \(maxFiles) ] && { echo "@@toobig $n"; exit 0; }
        G="\(root)/\(safe)"
        if [ ! -d "$G" ]; then mkdir -p "\(root)" && git init -q --bare "$G" && chmod 700 "$G"
          printf '%s\\n' .git node_modules .venv __pycache__ '*.pyc' .DS_Store > "$G/info/exclude"; fi
        \(g) add -A . 2>/dev/null
        if \(g) rev-parse -q --verify HEAD >/dev/null 2>&1 && \(g) diff --cached --quiet HEAD; then echo "@@unchanged $(\(g) rev-parse HEAD)"; exit 0; fi
        \(g) commit -q --allow-empty -m "turn $(date -u +%Y-%m-%dT%H:%M:%SZ)" && echo "@@checkpoint $(\(g) rev-parse HEAD)"
        """
    }

    /// Files changed since the task's first snapshot: `@@file <A|M|D>\t<path>` lines, then the diff of each.
    public static func changesCommand(task id: String, folder dir: String, maxDiff: Int = 300_000) -> String {
        let g = git(id, dir)
        return """
        command -v git >/dev/null 2>&1 || exit 0
        cd \(ServerTools.shellPath(dir)) 2>/dev/null || exit 0
        \(g) rev-parse -q --verify HEAD >/dev/null 2>&1 || exit 0
        base=$(\(g) rev-list --max-parents=0 HEAD | tail -n 1)
        \(g) add -A . 2>/dev/null
        \(g) diff --cached --no-renames --name-status "$base" | sed 's/^/@@file /'
        echo '@@diff'
        \(g) diff --cached --no-renames --no-color -U3 "$base" | head -c \(maxDiff)
        """
    }

    /// Puts files back as they were when the task began (all of them when `paths` is empty). New files are removed.
    public static func undoCommand(task id: String, folder dir: String, paths: [String] = []) -> String {
        let g = git(id, dir)
        let list = paths.map(ShellQuote.quote).joined(separator: " ")
        return """
        cd \(ServerTools.shellPath(dir)) 2>/dev/null || { echo '@@failed missing folder'; exit 0; }
        base=$(\(g) rev-list --max-parents=0 HEAD | tail -n 1)
        \(g) add -A . 2>/dev/null
        \(g) diff --cached --no-renames --name-status "$base" -- \(list) | while IFS="$(printf '\\t')" read -r st f; do
          case "$st" in A) rm -f -- "$f" ;; *) \(g) checkout "$base" -- "$f" ;; esac
        done
        \(g) add -A . 2>/dev/null
        echo '@@ok'
        """
    }

    /// Forgets the snapshots of a task.
    public static func removeCommand(task id: String) -> String {
        "rm -rf \"\(root)/\(id.filter { $0.isLetter || $0.isNumber || $0 == "-" })\""
    }

    public struct FileChange: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable { case added = "A", modified = "M", deleted = "D" }
        public var id: String { path }
        public var kind: Kind
        public var path: String
        public var diff: String
        public var added: Int { diff.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count }
        public var removed: Int { diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count }
    }

    public static func parseChanges(_ out: String) -> [FileChange] {
        guard let split = out.range(of: "@@diff\n") ?? out.range(of: "@@diff") else { return [] }
        var files: [FileChange] = []
        for line in out[..<split.lowerBound].split(separator: "\n") where line.hasPrefix("@@file ") {
            let p = line.dropFirst(7).split(separator: "\t", maxSplits: 1).map(String.init)
            guard p.count == 2, let k = FileChange.Kind(rawValue: String(p[0].prefix(1))) else { continue }
            files.append(FileChange(kind: k, path: p[1], diff: ""))
        }
        // Split the unified diff per file ("diff --git a/<path> b/<path>").
        var current: String?
        var chunks: [String: [Substring]] = [:]
        for line in out[split.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                current = line.components(separatedBy: " b/").last
                continue
            }
            if let c = current, !line.hasPrefix("index "), !line.hasPrefix("new file"), !line.hasPrefix("deleted file") { chunks[c, default: []].append(line) }
        }
        for i in files.indices { files[i].diff = (chunks[files[i].path] ?? []).joined(separator: "\n") }
        return files
    }
}
