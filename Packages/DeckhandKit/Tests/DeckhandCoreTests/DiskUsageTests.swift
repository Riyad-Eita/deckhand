import Foundation
import Testing
@testable import DeckhandCore

struct DiskUsageTests {
    @Test func scansAFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "du-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: dir + "/big folder", withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: URL(fileURLWithPath: dir + "/big folder/blob.bin"))
        try Data(count: 500_000).write(to: URL(fileURLWithPath: dir + "/small.log"))
        let r = try await LocalShell().run(DiskUsage.scanCommand(dir), timeout: .seconds(20))
        let scan = DiskUsage.parseScan(r.stdout)
        #expect(scan.entries.map(\.name) == ["big folder", "small.log"])
        #expect(scan.entries[0].isDirectory && !scan.entries[1].isDirectory)
        #expect(scan.entries[0].kilobytes >= 2900)
        #expect(scan.totalKB >= scan.entries[0].kilobytes + scan.entries[1].kilobytes)
        #expect(scan.directory.hasSuffix(String(dir.split(separator: "/").last!)))
        #expect(DiskUsage.parseScan(try await LocalShell().run(DiskUsage.scanCommand("/nonexistent-x"), timeout: .seconds(5)).stdout).missing)
    }

    @Test func protectsSystemFolders() {
        for p in ["/", "/etc", "/usr/", "/var/log", "/home/me", "/etc/nginx", "relative/path", "/srv/../etc"] {
            #expect(DiskUsage.protectionReason(p, home: "/home/me") != nil, "\(p)")
        }
        for p in ["/home/me/projects/old", "/var/log/nginx/access.log.5.gz", "/srv/app/node_modules"] {
            #expect(DiskUsage.protectionReason(p, home: "/home/me") == nil, "\(p)")
        }
        #expect(DiskUsage.deleteCommand("/srv/a b") == "rm -rf -- '/srv/a b' && echo '@@deleted'")
    }

    @Test func suggestions() {
        let s = DiskUsage.parseSuggestions("journal 3145728\napt 51200\noldlogs 2048\ndocker 2097152\ncache 409600\n", asRoot: true)
        #expect(s.map(\.id) == ["journal", "docker", "cache", "apt"])
        #expect(s.first { $0.id == "docker" }?.needsRoot == false)
        #expect(DiskUsage.parseSuggestions("journal 3145728\ncache 409600\n", asRoot: false).map(\.id) == ["cache"])
    }
}
