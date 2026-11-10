import Foundation

/// One running process with its CPU use over the last second (like top/htop, not the lifetime average of `ps`).
public struct ProcessInfoRow: Sendable, Hashable, Identifiable {
    public var pid: Int
    public var ppid: Int
    public var user: String
    /// Short name (`nginx`), from /proc/PID/stat.
    public var name: String
    /// Full command line; the name when unknown (kernel threads, BusyBox ps).
    public var command: String
    /// Percent of one core, so a busy multi-threaded process can exceed 100 (like top).
    public var cpu: Double
    public var rssKB: Int
    public var memFraction: Double
    public var state: String
    public var elapsed: TimeInterval?

    public var id: Int { pid }
    /// Kernel threads have no command line and can't be killed.
    public var isKernelThread: Bool { ppid == 2 || pid == 2 }

    public init(pid: Int, ppid: Int, user: String, name: String, command: String, cpu: Double, rssKB: Int,
                memFraction: Double, state: String, elapsed: TimeInterval?) {
        self.pid = pid; self.ppid = ppid; self.user = user; self.name = name; self.command = command
        self.cpu = cpu; self.rssKB = rssKB; self.memFraction = memFraction; self.state = state; self.elapsed = elapsed
    }
}

public struct ProcessSnapshot: Sendable, Hashable {
    public var processes: [ProcessInfoRow]
    public var cores: Int
    public var memTotalKB: Int
    /// The SSH user, to tell own processes from others.
    public var me: String
}

public enum ProcessSort: String, CaseIterable, Sendable { case cpu, memory, name }

public enum Processes {
    /// Two samples of /proc/*/stat one second apart, then ps for users and command lines.
    public static let command = [
        "echo \"@@me $(id -un) $(getconf CLK_TCK 2>/dev/null || echo 100) $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo) $(getconf PAGESIZE 2>/dev/null || echo 4096)\"",
        "grep MemTotal /proc/meminfo",
        "echo @@a; cat /proc/[0-9]*/stat 2>/dev/null",
        "sleep 1",
        "echo @@b; cat /proc/[0-9]*/stat 2>/dev/null",
        "echo @@ps; ps -eww -o pid=,user:32=,etimes=,args= 2>/dev/null || true",
    ].joined(separator: "; ")

    /// Fields of one /proc/PID/stat line. The name sits in parentheses and may itself contain spaces or `)`.
    struct Stat { var pid: Int; var name: String; var state: String; var ppid: Int; var ticks: Int; var rssPages: Int }

    static func parseStat(_ line: Substring) -> Stat? {
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"),
              let pid = Int(line[..<open].trimmingCharacters(in: .whitespaces)) else { return nil }
        let name = String(line[line.index(after: open)..<close])
        let rest = line[line.index(after: close)...].split(separator: " ")
        // rest[0] = state (field 3) … utime = field 14 → rest[11], stime = 15 → rest[12], rss = 24 → rest[21]
        guard rest.count > 21, let ppid = Int(rest[1]), let ut = Int(rest[11]), let st = Int(rest[12]), let rss = Int(rest[21]) else { return nil }
        return Stat(pid: pid, name: name, state: String(rest[0]), ppid: ppid, ticks: ut + st, rssPages: rss)
    }

    public static func parse(_ output: String, interval: Double = 1) -> ProcessSnapshot? {
        var me = "", hz = 100.0, cores = 1, memTotal = 0, pageKB = 4
        var first: [Int: Int] = [:]
        var second: [Int: Stat] = [:]
        var ps: [Int: (user: String, elapsed: TimeInterval?, args: String)] = [:]
        var section = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("@@me ") {
                let f = line.split(separator: " ")
                if f.count >= 4 { me = String(f[1]); hz = Double(f[2]) ?? 100; cores = Int(f[3]) ?? 1 }
                if f.count >= 5, let page = Int(f[4]), page >= 1024 { pageKB = page / 1024 }
                continue
            }
            if line.hasPrefix("MemTotal:") { memTotal = Int(line.split(separator: " ")[1]) ?? 0; continue }
            if line == "@@a" || line == "@@b" || line == "@@ps" { section = String(line); continue }
            switch section {
            case "@@a": if let s = parseStat(line) { first[s.pid] = s.ticks }
            case "@@b": if let s = parseStat(line) { second[s.pid] = s }
            case "@@ps":
                let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard f.count >= 3, let pid = Int(f[0]) else { continue }
                ps[pid] = (String(f[1]), Double(f[2]), f.count > 3 ? String(f[3]) : "")
            default: break
            }
        }
        guard !me.isEmpty, !second.isEmpty else { return nil }
        // Our own probe (the shell running this command, its timeout wrapper and ps) isn't interesting.
        let ownProbe = { (args: String) in args.contains("/proc/[0-9]*/stat") || args.hasPrefix("ps -eww -o pid=,user:32=") }
        let rows = second.values.filter { !ownProbe(ps[$0.pid]?.args ?? "") }.map { s -> ProcessInfoRow in
            let delta = first[s.pid].map { max(0, s.ticks - $0) } ?? 0
            let cpu = Double(delta) / hz / interval * 100
            let rss = s.rssPages * pageKB
            let info = ps[s.pid]
            let args = info?.args ?? ""
            return ProcessInfoRow(
                pid: s.pid, ppid: s.ppid, user: info?.user ?? "", name: displayName(comm: s.name, args: args),
                command: args.isEmpty ? "[\(s.name)]" : args,
                cpu: (cpu * 10).rounded() / 10, rssKB: rss,
                memFraction: memTotal > 0 ? Double(rss) / Double(memTotal) : 0,
                state: s.state, elapsed: info?.elapsed)
        }
        return ProcessSnapshot(processes: rows, cores: cores, memTotalKB: memTotal, me: me)
    }

    /// The kernel cuts names to 15 characters (`sshd-session.pa`); the command line usually has the full one.
    static func displayName(comm: String, args: String) -> String {
        guard comm.count >= 15, let first = args.split(separator: " ").first else { return comm }
        var base = String(first.split(separator: "/").last ?? first)
        if base.hasSuffix(":") { base.removeLast() }
        return base.hasPrefix(comm) ? base : comm
    }

    public static func sorted(_ rows: [ProcessInfoRow], by sort: ProcessSort, query: String = "", showKernel: Bool = false) -> [ProcessInfoRow] {
        rows
            .filter { showKernel || !$0.isKernelThread }
            .filter { query.isEmpty || $0.command.localizedCaseInsensitiveContains(query) || $0.user.localizedCaseInsensitiveContains(query) || String($0.pid) == query }
            .sorted { a, b in
                switch sort {
                case .cpu where a.cpu != b.cpu: return a.cpu > b.cpu
                case .memory where a.rssKB != b.rssKB: return a.rssKB > b.rssKB
                case .name:
                    let c = a.name.localizedCaseInsensitiveCompare(b.name)
                    if c != .orderedSame { return c == .orderedAscending }
                    return a.pid < b.pid
                default: return a.pid < b.pid
                }
            }
    }

    /// Ends a process: TERM, and KILL if it is still there after `grace` seconds. Refuses PID 1 and kernel threads.
    public static func killCommand(pid: Int, force: Bool = false, grace: Int = 5) -> String? {
        guard pid > 1 else { return nil }
        if force { return "kill -KILL \(pid)" }
        return "kill -TERM \(pid) || exit $?; for i in $(seq \(grace * 2)); do kill -0 \(pid) 2>/dev/null || exit 0; sleep 0.5; done; kill -KILL \(pid) 2>/dev/null; echo '@@killed'"
    }

    /// The reason a kill failed, in plain words.
    public static func killMessage(_ stderr: String) -> String {
        if stderr.contains("Operation not permitted") { return "This process belongs to another user." }
        if stderr.contains("No such process") { return "The process has already ended." }
        let line = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return line.isEmpty ? "The process couldn't be ended." : line
    }
}
