import Foundation

/// Git for repositories on the server: status, diffs, staging, commits, branches, pull and push.
/// Every command runs with `GIT_TERMINAL_PROMPT=0`, so missing credentials fail fast instead of hanging.
public enum Git {
    static func git(_ repo: String, _ args: String) -> String {
        "cd \(ServerTools.shellPath(repo)) && GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat LC_ALL=C git \(args)"
    }

    // MARK: Finding repositories

    /// Repositories up to three levels below the home folder (and the given folders), one path per line.
    public static func findCommand(extra: [String] = []) -> String {
        let roots = (["~"] + extra).map(ServerTools.shellPath).joined(separator: " ")
        return """
        for r in \(roots); do find "$r" -maxdepth 4 -name .git -type d -not -path '*/node_modules/*' -not -path '*/.cache/*' 2>/dev/null; done \
        | sed 's#/\\.git$##' | sort -u | head -n 100
        """
    }

    // MARK: Status

    public struct FileChange: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable { case modified, added, deleted, renamed, untracked, conflicted, typeChanged }
        public var path: String
        public var originalPath: String?
        public var staged: Kind?
        public var unstaged: Kind?
        public var id: String { path }
        public var isConflicted: Bool { staged == .conflicted || unstaged == .conflicted }
    }

    public struct Status: Sendable, Hashable {
        public var branch: String?
        public var upstream: String?
        public var ahead = 0
        public var behind = 0
        public var files: [FileChange] = []
        public var staged: [FileChange] { files.filter { $0.staged != nil } }
        public var unstaged: [FileChange] { files.filter { $0.unstaged != nil } }
        public var isClean: Bool { files.isEmpty }
    }

    public static func statusCommand(_ repo: String) -> String { git(repo, "status --porcelain=v2 --branch -z") }

    static func kind(_ c: Character) -> FileChange.Kind? {
        switch c {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R", "C": .renamed
        case "T": .typeChanged
        case "U": .conflicted
        default: nil
        }
    }

    /// Parses `git status --porcelain=v2 --branch -z`.
    public static func parseStatus(_ output: String) -> Status {
        var s = Status()
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = fields.popFirst() {
            if entry.hasPrefix("# branch.head ") {
                let b = String(entry.dropFirst(14)); s.branch = b == "(detached)" ? nil : b
            } else if entry.hasPrefix("# branch.upstream ") {
                s.upstream = String(entry.dropFirst(18))
            } else if entry.hasPrefix("# branch.ab ") {
                let p = entry.dropFirst(12).split(separator: " ")
                s.ahead = Int(p.first?.dropFirst() ?? "") ?? 0
                s.behind = Int(p.last?.dropFirst() ?? "") ?? 0
            } else if entry.hasPrefix("1 ") || entry.hasPrefix("2 ") || entry.hasPrefix("u ") {
                let parts = entry.split(separator: " ", maxSplits: entry.hasPrefix("1 ") ? 8 : (entry.hasPrefix("2 ") ? 9 : 10)).map(String.init)
                guard parts.count >= 2, let path = parts.last else { continue }
                let xy = Array(parts[1])
                var change = FileChange(path: path)
                if entry.hasPrefix("u ") {
                    change.staged = .conflicted; change.unstaged = .conflicted
                } else {
                    change.staged = kind(xy[0])
                    change.unstaged = kind(xy[1])
                }
                if entry.hasPrefix("2 ") { change.originalPath = fields.popFirst() }
                s.files.append(change)
            } else if entry.hasPrefix("? ") {
                s.files.append(FileChange(path: String(entry.dropFirst(2)), unstaged: .untracked))
            }
        }
        return s
    }

    // MARK: Diffs

    public static func diffCommand(_ repo: String, file: FileChange, staged: Bool) -> String {
        let p = ShellQuote.quote(file.path)
        if !staged && file.unstaged == .untracked {
            return git(repo, "diff --no-color --no-index -- /dev/null \(p); true")
        }
        return git(repo, "diff --no-color \(staged ? "--cached " : "")-M -- \(p)")
    }

    // MARK: Changes

    public static func stageCommand(_ repo: String, paths: [String]) -> String {
        git(repo, "add -A -- \(paths.map(ShellQuote.quote).joined(separator: " "))")
    }

    public static func unstageCommand(_ repo: String, paths: [String]) -> String {
        let p = paths.map(ShellQuote.quote).joined(separator: " ")
        return git(repo, "restore --staged -- \(p) 2>/dev/null || git reset -q -- \(p)")
    }

    /// Throws away unstaged changes (untracked files are deleted).
    public static func discardCommand(_ repo: String, file: FileChange) -> String {
        let p = ShellQuote.quote(file.path)
        return file.unstaged == .untracked ? git(repo, "clean -fd -- \(p)") : git(repo, "restore -- \(p) 2>/dev/null || git checkout -- \(p)")
    }

    public static func commitCommand(_ repo: String, message: String) -> String {
        git(repo, "commit -q -m \(ShellQuote.quote(message)) && git log -1 --format='%h %s'")
    }

    /// The staged diff, cut to `limit` bytes, for writing a commit message.
    public static func stagedDiffForMessage(_ repo: String, limit: Int = 24_000) -> String {
        git(repo, "diff --cached --no-color --stat && echo && git diff --cached --no-color | head -c \(limit)")
    }

    // MARK: Branches and history

    public struct Branch: Sendable, Hashable, Identifiable {
        public var name: String
        public var isCurrent: Bool
        public var upstream: String?
        public var id: String { name }
    }

    public static func branchesCommand(_ repo: String) -> String {
        git(repo, "for-each-ref --sort=-committerdate --format='%(HEAD)|%(refname:short)|%(upstream:short)' refs/heads")
    }

    public static func parseBranches(_ output: String) -> [Branch] {
        output.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 2, !p[1].isEmpty else { return nil }
            return Branch(name: p[1], isCurrent: p[0] == "*", upstream: p.count > 2 && !p[2].isEmpty ? p[2] : nil)
        }
    }

    public static func switchCommand(_ repo: String, branch: String, create: Bool = false) -> String {
        git(repo, "switch \(create ? "-c " : "")\(ShellQuote.quote(branch)) 2>&1 || git checkout \(create ? "-b " : "")\(ShellQuote.quote(branch))")
    }

    public static func isValidBranchName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: #"^(?!/|.*\.\.|.*//|.*@\{|.*\.lock$|.*/$)[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil
            && !name.hasPrefix("-")
    }

    public struct Commit: Sendable, Hashable, Identifiable {
        public var hash: String
        public var author: String
        public var date: Date
        public var subject: String
        public var id: String { hash }
    }

    public static func logCommand(_ repo: String, count: Int = 30) -> String {
        git(repo, "log -n \(count) --format='%h%x1f%an%x1f%at%x1f%s' 2>/dev/null")
    }

    public static func parseLog(_ output: String) -> [Commit] {
        output.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 4 else { return nil }
            return Commit(hash: p[0], author: p[1], date: Date(timeIntervalSince1970: Double(p[2]) ?? 0), subject: p[3])
        }
    }

    // MARK: Remote

    public static func pullCommand(_ repo: String) -> String { git(repo, "pull --ff-only 2>&1") }

    /// Pushes; sets the upstream on the first push of a new branch.
    public static func pushCommand(_ repo: String) -> String {
        git(repo, "push 2>&1 || { git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || git push -u origin HEAD 2>&1; }")
    }

    public static func fetchCommand(_ repo: String) -> String { git(repo, "fetch -q 2>&1; true") }

    /// A plain-language hint for common git failures.
    public static func hint(for output: String) -> String? {
        let o = output.lowercased()
        if o.contains("please tell me who you are") || o.contains("unable to auto-detect email") {
            return "Git doesn't know who you are on this server yet. Set your name and email in the repository settings."
        }
        if o.contains("terminal prompts disabled") || o.contains("could not read username") || o.contains("authentication failed") || o.contains("permission denied (publickey)") {
            return "The server has no credentials for this remote. Connect GitHub in Connections, or add an SSH key for the server."
        }
        if o.contains("not possible to fast-forward") || o.contains("diverging branches") {
            return "Your branch and the remote have both moved on. Ask an agent to merge or rebase them."
        }
        if o.contains("rejected") && o.contains("fetch first") {
            return "The remote has commits you don't have yet. Pull first, then push."
        }
        return nil
    }

    public static func setIdentityCommand(_ repo: String, name: String, email: String) -> String {
        git(repo, "config user.name \(ShellQuote.quote(name)) && git config user.email \(ShellQuote.quote(email))")
    }

    public static func identityCommand(_ repo: String) -> String {
        git(repo, "config user.name; echo '@@'; git config user.email")
    }

    /// The prompt for a commit message from the staged diff.
    public static func commitMessagePrompt(diff: String) -> String {
        """
        Write a git commit message for the staged changes below. Imperative mood, a subject line under 72 characters, \
        then (only if it helps) a blank line and a short body explaining why. Reply with the message only — no quotes, \
        no code fences.

        \(diff)
        """
    }
}
