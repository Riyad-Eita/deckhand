import Foundation

/// A snapshot of a Linux server's health, gathered with one command (no agent needed on the server).
public struct ServerStats: Sendable, Hashable {
    public struct Disk: Sendable, Hashable, Identifiable {
        public var mount: String
        public var totalKB: Int64
        public var usedKB: Int64
        public var availableKB: Int64
        public var id: String { mount }
        /// Like `df`: space reserved for root doesn't count as available to users.
        public var usedFraction: Double {
            usedKB + availableKB > 0 ? Double(usedKB) / Double(usedKB + availableKB) : 0
        }
    }

    /// 0…1 over the sampling window.
    public var cpu: Double
    public var cores: Int
    public var load: (Double, Double, Double)
    public var memTotalKB: Int64
    public var memAvailableKB: Int64
    public var swapTotalKB: Int64
    public var swapFreeKB: Int64
    public var uptime: TimeInterval
    public var disks: [Disk]

    public var memUsedFraction: Double {
        memTotalKB > 0 ? Double(memTotalKB - memAvailableKB) / Double(memTotalKB) : 0
    }

    /// Things worth flagging, most important first.
    public var warnings: [String] {
        var w: [String] = []
        for d in disks where d.usedFraction >= 0.85 {
            w.append("\(d.mount) is \(Int((d.usedFraction * 100).rounded(.up))) % full")
        }
        if memUsedFraction >= 0.9 { w.append("Memory is almost exhausted") }
        if cores > 0 && load.0 > Double(cores) * 1.5 { w.append("Load is high for \(cores) cores") }
        return w
    }

    public static func == (a: ServerStats, b: ServerStats) -> Bool {
        a.cpu == b.cpu && a.cores == b.cores && a.load == b.load && a.memTotalKB == b.memTotalKB
            && a.memAvailableKB == b.memAvailableKB && a.uptime == b.uptime && a.disks == b.disks
    }

    public func hash(into h: inout Hasher) {
        h.combine(cpu); h.combine(memAvailableKB); h.combine(uptime); h.combine(disks)
    }

    /// Two /proc/stat samples half a second apart, memory, load, uptime, cores and real filesystems.
    public static let probeCommand = """
    echo '@@cpu1'; head -1 /proc/stat; sleep 0.5; echo '@@cpu2'; head -1 /proc/stat
    echo '@@mem'; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
    echo '@@load'; cat /proc/loadavg
    echo '@@uptime'; cut -d' ' -f1 /proc/uptime
    echo '@@cores'; nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo
    echo '@@df'; df -P -k -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null
    """

    public static func parse(_ output: String) -> ServerStats? {
        var sections: [String: [String]] = [:]
        var current = ""
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@") { current = String(line.dropFirst(2)); continue }
            sections[current, default: []].append(line)
        }
        func cpuTimes(_ key: String) -> (busy: Double, total: Double)? {
            guard let line = sections[key]?.first, line.hasPrefix("cpu") else { return nil }
            let v = line.split(separator: " ").dropFirst().compactMap { Double($0) }
            guard v.count >= 4 else { return nil }
            let idle = v[3] + (v.count > 4 ? v[4] : 0)
            let total = v.reduce(0, +)
            return (total - idle, total)
        }
        guard let a = cpuTimes("cpu1"), let b = cpuTimes("cpu2") else { return nil }
        let dt = b.total - a.total
        let cpu = dt > 0 ? max(0, min(1, (b.busy - a.busy) / dt)) : 0

        var mem: [String: Int64] = [:]
        for line in sections["mem"] ?? [] {
            let parts = line.split(whereSeparator: { $0 == ":" || $0 == " " })
            if parts.count >= 2, let v = Int64(parts[1]) { mem[String(parts[0])] = v }
        }
        let loads = (sections["load"]?.first ?? "").split(separator: " ").prefix(3).compactMap { Double($0) }
        let uptime = Double(sections["uptime"]?.first ?? "") ?? 0
        let cores = Int(sections["cores"]?.first ?? "") ?? 0

        var disks: [Disk] = []
        for line in (sections["df"] ?? []).dropFirst() {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 6, let total = Int64(p[1]), let used = Int64(p[2]), let avail = Int64(p[3]), total > 0 else { continue }
            let mount = p[5...].joined(separator: " ")
            if mount.hasPrefix("/boot") || mount.hasPrefix("/snap") { continue }
            disks.append(Disk(mount: mount, totalKB: total, usedKB: used, availableKB: avail))
        }

        return ServerStats(
            cpu: cpu, cores: cores,
            load: (loads.count > 0 ? loads[0] : 0, loads.count > 1 ? loads[1] : 0, loads.count > 2 ? loads[2] : 0),
            memTotalKB: mem["MemTotal"] ?? 0, memAvailableKB: mem["MemAvailable"] ?? 0,
            swapTotalKB: mem["SwapTotal"] ?? 0, swapFreeKB: mem["SwapFree"] ?? 0,
            uptime: uptime, disks: disks)
    }
}

public enum ByteFormat {
    public static func kb(_ kb: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: kb * 1024, countStyle: .binary)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let d = Int(seconds) / 86400, h = Int(seconds) % 86400 / 3600, m = Int(seconds) % 3600 / 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
