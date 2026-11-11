import Foundation

/// Where the disk space goes (like ncdu), what can be cleaned up safely, and deleting with care.
public enum DiskUsage {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var path: String
        public var kilobytes: Int64
        public var isDirectory: Bool
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
    }

    /// Lists the biggest entries directly inside `path` (one filesystem, files and folders).
    /// Output: `D|F <kb> <path>` per entry, then `@@total <kb>`.
    public static func scanCommand(_ path: String) -> String {
        let p = ServerTools.shellPath(path)
        return """
        cd \(p) 2>/dev/null || { echo '@@missing'; exit 0; }
        D=$(pwd)
        # Folders with du -d 1, files with find (BSD du can't combine -a and -d).
        { du -xk -d 1 "$D" 2>/dev/null; find "$D" -mindepth 1 -maxdepth 1 -type f -exec du -k {} + 2>/dev/null; } \
          | sort -rn | head -n 80 | while IFS="$(printf '\\t')" read -r kb f; do
          if [ "$f" = "$D" ]; then echo "@@total $kb"; elif [ -d "$f" ]; then echo "D $kb $f"; else echo "F $kb $f"; fi
        done
        echo "@@dir $D"
        """
    }

    public struct Scan: Sendable, Hashable {
        public var directory: String
        public var totalKB: Int64
        public var entries: [Entry]
        public var missing: Bool
    }

    public static func parseScan(_ output: String) -> Scan {
        var s = Scan(directory: "", totalKB: 0, entries: [], missing: false)
        for line in output.split(separator: "\n").map(String.init) {
            if line == "@@missing" { s.missing = true; continue }
            if line.hasPrefix("@@total ") { s.totalKB = Int64(line.dropFirst(8)) ?? 0; continue }
            if line.hasPrefix("@@dir ") { s.directory = String(line.dropFirst(6)); continue }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let kb = Int64(parts[1]) else { continue }
            s.entries.append(Entry(path: parts[2], kilobytes: kb, isDirectory: parts[0] == "D"))
        }
        s.entries.sort { $0.kilobytes > $1.kilobytes }
        return s
    }

    // MARK: Deleting

    static let protectedPaths: Set<String> = [
        "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib32", "/lib64", "/libx32", "/media", "/mnt", "/opt",
        "/proc", "/root", "/run", "/sbin", "/srv", "/sys", "/tmp", "/usr", "/var", "/var/lib", "/var/log", "/var/cache",
        "/var/lib/docker", "/usr/local", "/usr/bin", "/usr/lib", "/usr/sbin", "/snap",
    ]

    /// Why `path` must not be deleted from here, or nil.
    public static func protectionReason(_ path: String, home: String) -> String? {
        let clean = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if protectedPaths.contains(clean) { return "System folder — deleting it would break the server." }
        if clean == home || clean == (home as NSString).deletingLastPathComponent { return "That's a home folder." }
        if !clean.hasPrefix("/") || clean.contains("/../") || clean.hasSuffix("/..") { return "Not a full path." }
        if clean.hasPrefix("/usr/") || clean.hasPrefix("/bin/") || clean.hasPrefix("/sbin/") || clean.hasPrefix("/lib")
            || clean.hasPrefix("/boot/") || clean.hasPrefix("/etc/") || clean.hasPrefix("/proc/") || clean.hasPrefix("/sys/") {
            return "Part of the operating system."
        }
        return nil
    }

    public static func deleteCommand(_ path: String) -> String {
        "rm -rf -- \(ShellQuote.quote(path)) && echo '@@deleted'"
    }

    // MARK: Suggestions

    public struct Suggestion: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String
        public var kilobytes: Int64
        /// The cleanup command.
        public var command: String
        public var needsRoot: Bool
    }

    /// Measures the usual suspects. Run as root for the system ones (they're skipped otherwise).
    public static let suggestionsScript = #"""
    k() { du -sk "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
    if command -v journalctl >/dev/null 2>&1; then
      j=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -n 1)
      case "$j" in *K) n=${j%K};; *M) n=$(awk "BEGIN{print ${j%M}*1024}");; *G) n=$(awk "BEGIN{print ${j%G}*1048576}");; *T) n=$(awk "BEGIN{print ${j%T}*1073741824}");; *) n=0;; esac
      echo "journal ${n%.*}"
    fi
    [ -d /var/cache/apt/archives ] && echo "apt $(k /var/cache/apt/archives)"
    [ -d /var/cache/dnf ] && echo "dnf $(k /var/cache/dnf)"
    echo "oldlogs $(find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -exec du -sk {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    [ -d /var/lib/systemd/coredump ] && echo "coredumps $(k /var/lib/systemd/coredump)"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      echo "docker $(docker system df --format '{{.Reclaimable}}' 2>/dev/null | grep -oE '^[0-9.]+[kMGT]?B' | awk '
        /kB$/ {s+=$1} /MB$/ {s+=$1*1024} /GB$/ {s+=$1*1048576} /TB$/ {s+=$1*1073741824} END {print int(s)}')"
    fi
    [ -d "$HOME/.cache" ] && echo "cache $(k "$HOME/.cache")"
    [ -d "$HOME/.npm/_cacache" ] && echo "npm $(k "$HOME/.npm/_cacache")"
    [ -d "$HOME/.local/share/Trash" ] && echo "trash $(k "$HOME/.local/share/Trash")"
    true
    """#

    public static func parseSuggestions(_ output: String, asRoot: Bool) -> [Suggestion] {
        var sizes: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let p = line.split(separator: " ")
            if p.count == 2, let kb = Int64(p[1]) { sizes[String(p[0])] = kb }
        }
        let all: [(String, String, String, String, Bool)] = [
            ("journal", "System journal", "Keeps the last 100 MB of logs.", "journalctl --vacuum-size=100M", true),
            ("apt", "Downloaded packages", "Installed packages stay; only the download cache goes.", "apt-get clean", true),
            ("dnf", "Downloaded packages", "Installed packages stay; only the download cache goes.", "dnf clean all", true),
            ("oldlogs", "Old rotated logs", "Compressed and numbered log files from earlier days.", "find /var/log -type f \\( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \\) -delete", true),
            ("coredumps", "Crash dumps", "Memory dumps from crashed programs.", "rm -rf /var/lib/systemd/coredump/*", true),
            ("docker", "Unused Docker data", "Stopped containers, unused networks, dangling images and build cache. Running containers and volumes stay.", "docker system prune -f", false),
            ("cache", "Your cache folder", "~/.cache — programs rebuild it when needed.", "rm -rf \"$HOME\"/.cache/*", false),
            ("npm", "npm cache", "Downloaded npm packages.", "npm cache clean --force 2>/dev/null || rm -rf \"$HOME\"/.npm/_cacache", false),
            ("trash", "Trash", "Files moved to the trash on the server.", "rm -rf \"$HOME\"/.local/share/Trash/*", false),
        ]
        return all.compactMap { id, title, detail, command, root in
            guard let kb = sizes[id], kb >= 10_240, !root || asRoot else { return nil }   // at least 10 MB
            return Suggestion(id: id, title: title, detail: detail, kilobytes: kb, command: command, needsRoot: root)
        }
        .sorted { $0.kilobytes > $1.kilobytes }
    }
}
