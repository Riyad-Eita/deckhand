import Foundation

/// One entry of a folder on the server.
public struct RemoteFile: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case folder, file, link, other }

    public var name: String
    public var kind: Kind
    /// A folder, or a link that points to one.
    public var opensAsFolder: Bool
    public var size: Int64
    public var modified: Date
    /// Octal permissions, e.g. `644`.
    public var mode: String
    /// Where a link points to.
    public var linkTarget: String?

    public var id: String { name }
    public var isHidden: Bool { name.hasPrefix(".") }

    public init(name: String, kind: Kind, opensAsFolder: Bool, size: Int64, modified: Date, mode: String, linkTarget: String? = nil) {
        self.name = name
        self.kind = kind
        self.opensAsFolder = opensAsFolder
        self.size = size
        self.modified = modified
        self.mode = mode
        self.linkTarget = linkTarget
    }
}

/// The content of one folder.
public struct RemoteFolder: Sendable, Hashable {
    /// Absolute path with symlinks resolved.
    public var path: String
    public var entries: [RemoteFile]
    /// The user may create, rename and delete entries here.
    public var writable: Bool
    /// More entries than `RemoteFiles.limit`; only the first ones are shown.
    public var truncated: Bool
}

public enum FileSort: String, CaseIterable, Sendable {
    case name, modified, size
}

/// Browse and change files on the server with plain shell commands (no SFTP subsystem needed).
public enum RemoteFiles {
    public static let limit = 2000

    /// Lists a folder. Records are NUL-terminated `type/targetType/size/mtime/mode/name/linkTarget`: a name can't
    /// contain `/` or NUL, so names with spaces, tabs or newlines survive. GNU find, with a POSIX fallback (BusyBox).
    public static func listCommand(_ path: String) -> String {
        let p = ServerTools.shellPath(path)
        let fallback = #"""
        n=0; for f in .[!.]* ..?* *; do { [ -e "$f" ] || [ -L "$f" ]; } || continue; n=$((n+1)); [ $n -gt \#(limit + 1) ] && break; \#
        if [ -L "$f" ]; then y=l; elif [ -d "$f" ]; then y=d; elif [ -f "$f" ]; then y=f; else y=o; fi; \#
        if [ -d "$f" ]; then t=d; else t=f; fi; \#
        printf '%s/%s/%s/%s/%s\0' "$y" "$t" "$(stat -c '%s/%Y/%a' -- "$f" 2>/dev/null || echo 0/0/0)" "$f" "$(readlink -- "$f" 2>/dev/null)"; done
        """#
        return "cd -- \(p) && pwd -P && { [ -w . ] && echo rw || echo ro; } && "
            + "if find . -maxdepth 0 -printf '' 2>/dev/null; then "
            + "find . -mindepth 1 -maxdepth 1 -printf '%y/%Y/%s/%T@/%m/%f/%l\\0' 2>/dev/null | head -z -n \(limit + 1); "
            + "else \(fallback); fi"
    }

    public static func parse(_ output: String) -> RemoteFolder? {
        let header = output.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard header.count >= 2, header[0].hasPrefix("/") else { return nil }
        let path = String(header[0])
        let writable = header[1] == "rw"
        let body = header.count > 2 ? header[2] : ""
        var entries: [RemoteFile] = []
        for record in body.split(separator: "\0", omittingEmptySubsequences: true) {
            let f = record.split(separator: "/", maxSplits: 6, omittingEmptySubsequences: false)
            guard f.count >= 6 else { continue }
            let name = String(f[5])
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            let kind: RemoteFile.Kind = switch f[0] {
            case "d": .folder
            case "f": .file
            case "l": .link
            default: .other
            }
            let target = f.count > 6 && !f[6].isEmpty ? String(f[6]) : nil
            entries.append(RemoteFile(
                name: name, kind: kind,
                opensAsFolder: kind == .folder || (kind == .link && f[1] == "d"),
                size: Int64(f[2]) ?? 0,
                modified: Date(timeIntervalSince1970: Double(f[3]) ?? 0),
                mode: String(f[4]),
                linkTarget: kind == .link ? target : nil))
        }
        let truncated = entries.count > limit
        return RemoteFolder(path: path, entries: Array(entries.prefix(limit)), writable: writable, truncated: truncated)
    }

    /// Folders first, then files; hidden entries only when asked for.
    public static func sorted(_ entries: [RemoteFile], by sort: FileSort, showHidden: Bool) -> [RemoteFile] {
        entries
            .filter { showHidden || !$0.isHidden }
            .sorted { a, b in
                if a.opensAsFolder != b.opensAsFolder { return a.opensAsFolder }
                switch sort {
                case .modified where a.modified != b.modified: return a.modified > b.modified
                case .size where !a.opensAsFolder && a.size != b.size: return a.size > b.size
                default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
    }

    // MARK: - Changes

    public enum NameProblem: Error, Equatable, Sendable {
        case empty, dots, slash, tooLong
    }

    /// Checks a new file or folder name; returns the trimmed name.
    public static func validName(_ raw: String) throws(NameProblem) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw .empty }
        if name == "." || name == ".." { throw .dots }
        if name.contains("/") || name.contains("\0") { throw .slash }
        if name.utf8.count > 255 { throw .tooLong }
        return name
    }

    public static func renameCommand(in folder: String, from old: String, to new: String) -> String {
        let src = ShellQuote.quote(DirectoryListing.join(folder, old))
        let dst = ShellQuote.quote(DirectoryListing.join(folder, new))
        return "if [ -e \(dst) ] || [ -L \(dst) ]; then echo 'Something with that name already exists.' >&2; exit 3; fi; mv -- \(src) \(dst)"
    }

    public static func makeFolderCommand(in folder: String, name: String) -> String {
        "mkdir -- \(ShellQuote.quote(DirectoryListing.join(folder, name)))"
    }

    /// Paths the app refuses to delete: `/`, top-level folders like `/etc`, and the home folder (checked on the server).
    public static func isProtected(_ path: String) -> Bool {
        let parts = path.split(separator: "/").filter { $0 != "." }
        return !path.hasPrefix("/") || parts.count < 2 || parts.contains("..")
    }

    /// Deletes a file or folder (with everything in it). Refuses protected paths and the home folder.
    public static func deleteCommand(_ path: String) -> String? {
        guard !isProtected(path) else { return nil }
        let p = ShellQuote.quote(path)
        return "if [ \"$(cd -- \(p) 2>/dev/null && pwd -P)\" = \"$(cd ~ && pwd -P)\" ]; then echo 'Refusing to delete the home folder.' >&2; exit 4; fi; rm -rf -- \(p)"
    }

    // MARK: - Running

    public static func list(_ path: String, shell: any RemoteShell) async throws -> RemoteFolder {
        let r = try await shell.run(listCommand(path), timeout: .seconds(30))
        guard r.exitCode == 0, let folder = parse(r.stdout) else {
            throw ToolError.failed(message(r, or: "Can't open \(path)"))
        }
        return folder
    }

    public static func rename(in folder: String, from old: String, to new: String, shell: any RemoteShell) async throws {
        let name = try validName(new)
        guard name != old else { return }
        try await check(shell.run(renameCommand(in: folder, from: old, to: name), timeout: .seconds(30)), or: "Can't rename \(old)")
    }

    public static func makeFolder(in folder: String, name raw: String, shell: any RemoteShell) async throws {
        let name = try validName(raw)
        try await check(shell.run(makeFolderCommand(in: folder, name: name), timeout: .seconds(30)), or: "Can't create \(name)")
    }

    public static func delete(_ path: String, shell: any RemoteShell) async throws {
        guard let command = deleteCommand(path) else { throw ToolError.failed("Deckhand doesn't delete \(path).") }
        try await check(shell.run(command, timeout: .seconds(120)), or: "Can't delete \(path)")
    }

    private static func check(_ r: CommandResult, or fallback: String) throws {
        guard r.exitCode == 0 else { throw ToolError.failed(message(r, or: fallback)) }
    }

    /// The last stderr line; tool errors like `mv: cannot move 'a' to 'b': Permission denied` become
    /// "Can't rename a: Permission denied".
    static func message(_ r: CommandResult, or fallback: String) -> String {
        let e = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = e.split(separator: "\n").last.map(String.init) else { return fallback }
        if line.range(of: #"^(mv|mkdir|rm|sh|bash|dash|cd|-bash)[: ]"#, options: .regularExpression) != nil,
           let reason = line.components(separatedBy: ": ").last, !reason.isEmpty {
            return "\(fallback): \(reason)"
        }
        return line
    }
}

extension RemoteFiles.NameProblem: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty: String(localized: "Enter a name.")
        case .dots: String(localized: "“.” and “..” can't be used as names.")
        case .slash: String(localized: "Names can't contain “/”.")
        case .tooLong: String(localized: "That name is too long.")
        }
    }
}
