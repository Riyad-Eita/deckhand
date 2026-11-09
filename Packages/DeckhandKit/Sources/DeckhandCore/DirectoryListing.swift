import Foundation

/// Lists the sub-folders of a directory on the server, for the folder picker.
public struct DirectoryListing: Sendable, Hashable {
    /// Absolute path after resolving `~` and symlinks.
    public var path: String
    public var folders: [String]
    /// True when the folder is a git repository (has .git).
    public var isGitRepo: Bool

    public static func command(_ path: String) -> String {
        let p = ServerTools.shellPath(path)
        return "cd \(p) && pwd && { [ -e .git ] && echo '@@git' || true; } && ls -1Ap | grep '/$' | head -500"
    }

    public static func parse(_ output: String) -> DirectoryListing? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first, first.hasPrefix("/") else { return nil }
        lines.removeFirst()
        var git = false
        if lines.first == "@@git" { git = true; lines.removeFirst() }
        let folders = lines.map { String($0.dropLast()) }
            .filter { $0 != "." && $0 != ".." }
            .sorted { a, b in
                // Visible folders first, then hidden; alphabetical, case-insensitive.
                let ha = a.hasPrefix("."), hb = b.hasPrefix(".")
                return ha != hb ? !ha : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        return DirectoryListing(path: first, folders: folders, isGitRepo: git)
    }

    public static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }
}
