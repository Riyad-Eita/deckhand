import Foundation
import Testing
@testable import DeckhandCore

@Suite struct ProcessesTests {
    static func stat(_ pid: Int, _ name: String, state: String = "S", ppid: Int = 1, ticks: (Int, Int), rss: Int) -> String {
        // pid (name) state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime
        // priority nice threads itrealvalue starttime vsize rss …
        "\(pid) (\(name)) \(state) \(ppid) 1 1 0 -1 4194560 100 0 0 0 \(ticks.0) \(ticks.1) 0 0 20 0 1 0 100 1000000 \(rss) 18446744073709551615"
    }

    static let sample = [
        "@@me me 100 4 4096",
        "MemTotal:        8000000 kB",
        "@@a",
        stat(1, "systemd", ticks: (100, 50), rss: 3000),
        stat(2, "kthreadd", ppid: 0, ticks: (0, 0), rss: 0),
        stat(120, "kworker/0:1", ppid: 2, ticks: (10, 10), rss: 0),
        stat(800, "node", ticks: (1000, 200), rss: 50000),
        stat(900, "my (weird) app", ticks: (5, 5), rss: 1000),
        "@@b",
        stat(1, "systemd", ticks: (100, 51), rss: 3000),
        stat(2, "kthreadd", ppid: 0, ticks: (0, 0), rss: 0),
        stat(120, "kworker/0:1", ppid: 2, ticks: (10, 12), rss: 0),
        stat(800, "node", ticks: (1120, 230), rss: 50000),
        stat(900, "my (weird) app", ticks: (5, 6), rss: 1000),
        stat(950, "sleep", ticks: (0, 0), rss: 200),
        stat(960, "sshd-session.pa", ticks: (0, 0), rss: 900),
        stat(970, "bash", ticks: (1, 1), rss: 300),
        "@@ps",
        "    960 me                                      50 sshd-session.pam: me [priv]",
        "    970 me                                       1 bash -lc echo \"@@me\"; cat /proc/[0-9]*/stat 2>/dev/null",
        "      1 root                                 86400 /sbin/init splash",
        "    800 me                                    3600 node /srv/app/server.js --port 3000",
        "    900 www-data                                12 ./my (weird) app",
        "    950 me                                       0 sleep 30",
    ].joined(separator: "\n")

    @Test func parsesTwoSamplesIntoCPUAndMemory() throws {
        let snap = try #require(Processes.parse(Self.sample))
        #expect(snap.me == "me" && snap.cores == 4 && snap.memTotalKB == 8_000_000)
        let node = try #require(snap.processes.first { $0.pid == 800 })
        #expect(node.cpu == 150)                     // 150 ticks in 1 s at 100 Hz = 1.5 cores
        #expect(node.rssKB == 200_000)                // 50000 pages × 4 KB
        #expect(abs(node.memFraction - 0.025) < 0.0001)
        #expect(node.user == "me" && node.command == "node /srv/app/server.js --port 3000" && node.elapsed == 3600)
        let weird = try #require(snap.processes.first { $0.pid == 900 })
        #expect(weird.name == "my (weird) app" && weird.cpu == 1 && weird.user == "www-data")
        let fresh = try #require(snap.processes.first { $0.pid == 950 })
        #expect(fresh.cpu == 0)                       // started between the samples
        let kworker = try #require(snap.processes.first { $0.pid == 120 })
        #expect(kworker.isKernelThread && kworker.command == "[kworker/0:1]")
        #expect(snap.processes.first { $0.pid == 960 }?.name == "sshd-session.pam")
        #expect(!snap.processes.contains { $0.pid == 970 })   // our own probe
    }

    @Test func fullNamesFromCommandLine() {
        #expect(Processes.displayName(comm: "s6-linux-init-s", args: "/package/admin/s6-linux-init-shutdownd -c /etc") == "s6-linux-init-shutdownd")
        #expect(Processes.displayName(comm: "node", args: "node server.js") == "node")
        #expect(Processes.displayName(comm: "kworker/u8:2-ev", args: "") == "kworker/u8:2-ev")
        #expect(Processes.displayName(comm: "python3.12-thre", args: "/usr/bin/python3 app.py") == "python3.12-thre")
    }

    @Test func sortsAndFilters() throws {
        let rows = try #require(Processes.parse(Self.sample)).processes
        #expect(Processes.sorted(rows, by: .cpu).map(\.pid) == [800, 1, 900, 950, 960])
        #expect(Processes.sorted(rows, by: .memory).map(\.pid).first == 800)
        #expect(Processes.sorted(rows, by: .name).map(\.name) == ["my (weird) app", "node", "sleep", "sshd-session.pam", "systemd"])
        #expect(Processes.sorted(rows, by: .cpu, showKernel: true).count == 7)
        #expect(Processes.sorted(rows, by: .cpu, query: "server.js").map(\.pid) == [800])
        #expect(Processes.sorted(rows, by: .cpu, query: "www").map(\.pid) == [900])
        #expect(Processes.sorted(rows, by: .cpu, query: "950").map(\.pid) == [950])
    }

    @Test func rejectsEmptyOutput() {
        #expect(Processes.parse("") == nil)
        #expect(Processes.parse("@@me me 100 1\n@@a\n@@b\n") == nil)
    }

    @Test func killCommands() {
        #expect(Processes.killCommand(pid: 1) == nil)
        #expect(Processes.killCommand(pid: 0) == nil)
        #expect(Processes.killCommand(pid: 800, force: true) == "kill -KILL 800")
        let soft = Processes.killCommand(pid: 800)
        #expect(soft?.hasPrefix("kill -TERM 800") == true)
        #expect(soft?.contains("kill -KILL 800") == true)
        #expect(Processes.killMessage("bash: kill: (900) - Operation not permitted") == "This process belongs to another user.")
        #expect(Processes.killMessage("kill: (900) - No such process\n") == "The process has already ended.")
    }
}
