import Foundation
import Testing
@testable import DeckhandCore

struct ChangeHistoryTests {
    @Test func parsesTimeline() {
        let out = """
        @@diff yes
        @@cron
        @@installed
        @@c b2c3d4e 1762000900 snapshot|pkg apt-get install -y cron|agent 1

        M\tpackages.txt
        A\tetc/cron.d/e2scrub_all
        M\tservices.txt
        @@c a1b2c3d 1762000000 start

        A\tpackages.txt
        """
        let t = ChangeHistory.parseTimeline(out)
        #expect(t.hasDiff && t.installed && t.cron)
        #expect(t.snapshots.count == 2)
        #expect(t.snapshots[0].causes == [.packageManager("apt-get install -y cron"), .agent(1)])
        #expect(t.snapshots[0].categories == [.packages: 1, .config: 1, .services: 1])
        #expect(t.snapshots[1].isStart)
    }

    @Test func pairsChangedEntries() {
        let diff = """
        diff -rN -U0 state/packages.txt next/packages.txt
        --- state/packages.txt	2026-11-11 10:00:00
        +++ next/packages.txt	2026-11-11 10:15:00
        @@ -3 +3 @@
        -nginx 1.24.0-2
        +nginx 1.26.0-1
        @@ -9,0 +10 @@
        +cron 3.0pl1
        @@ -12 +12,0 @@
        -telnet 0.17
        diff -rN -U0 state/etc/nginx/nginx.conf next/etc/nginx/nginx.conf
        --- state/etc/nginx/nginx.conf	2026-11-11 10:00:00
        +++ next/etc/nginx/nginx.conf	2026-11-11 10:15:00
        @@ -4 +4 @@
        -    gzip on;
        +    gzipp on;
        diff -rN -U0 state/ports.txt next/ports.txt
        @@ -1,0 +2 @@
        +0.0.0.0:5432
        """
        let files = ChangeHistory.parseDiff(diff)
        #expect(files.map(\.path) == ["packages.txt", "etc/nginx/nginx.conf", "ports.txt"])
        let pkg = ChangeHistory.changes(in: files[0])
        #expect(pkg.contains(.init(kind: .changed, key: "nginx", old: "1.24.0-2", new: "1.26.0-1")))
        #expect(pkg.contains(.init(kind: .added, key: "cron", old: nil, new: "3.0pl1")))
        #expect(pkg.contains(.init(kind: .removed, key: "telnet", old: "0.17", new: nil)))
        #expect(ChangeHistory.changes(in: files[2]) == [.init(kind: .added, key: "0.0.0.0:5432", old: nil, new: "")])
        let text = ChangeHistory.summary(files)
        #expect(text.contains("packages: nginx 1.24.0-2 → 1.26.0-1"))
        #expect(text.contains("changed /etc/nginx/nginx.conf (+1 −1)"))
        #expect(text.contains("  + " + "    gzipp on;"))
    }

    @Test func consecutiveDiffsAddUp() {
        let diff = """
        diff -rN -U0 state/packages.txt next/packages.txt
        -nginx 1.24
        +nginx 1.25
        diff -rN -U0 state/etc/new.conf next/etc/new.conf
        --- state/etc/new.conf\t1970-01-01 00:00:00
        +++ next/etc/new.conf\t2026-11-11 10:15:00
        +a = 1
        diff -rN -U0 state/packages.txt next/packages.txt
        -nginx 1.25
        +nginx 1.26
        diff -rN -U0 state/ports.txt next/ports.txt
        +0.0.0.0:8080
        diff -rN -U0 state/ports.txt next/ports.txt
        -0.0.0.0:8080
        """
        let files = ChangeHistory.parseDiff(diff)
        #expect(files.map(\.path) == ["packages.txt", "etc/new.conf"])
        #expect(ChangeHistory.changes(in: files[0]) == [.init(kind: .changed, key: "nginx", old: "1.24", new: "1.26")])
        #expect(files[1].isNew)
    }

    @Test func snapshotsRecordConfigChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hist-\(UUID().uuidString.prefix(6))").path
        let etc = root + "/etc"
        try FileManager.default.createDirectory(atPath: etc + "/app", withIntermediateDirectories: true)
        try "port = 80\n".write(toFile: etc + "/app/app.conf", atomically: true, encoding: .utf8)
        try "secret\n".write(toFile: etc + "/app/server.key", atomically: true, encoding: .utf8)
        let d = root + "/.deckhand/history"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        try ChangeHistory.snapshotScript.write(toFile: d + "/snap.sh", atomically: true, encoding: .utf8)
        // Stable stand-ins for the host's ports and crontab, so only our config change shows up.
        let bin = root + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*'\n".write(toFile: bin + "/ss", atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 1\n".write(toFile: bin + "/crontab", atomically: true, encoding: .utf8)
        let shell = LocalShell()
        _ = try await shell.run("chmod +x '\(bin)/ss' '\(bin)/crontab'", timeout: .seconds(5))
        let env = "HOME='\(root)' ETC='\(etc)' PATH='\(bin)':$PATH"
        _ = try await shell.run("\(env) sh '\(d)/snap.sh'", timeout: .seconds(60))
        try "port = 8080\n".write(toFile: etc + "/app/app.conf", atomically: true, encoding: .utf8)
        _ = try await shell.run("\(env) sh '\(d)/snap.sh'; \(env) sh '\(d)/snap.sh'", timeout: .seconds(60))

        let log = try await shell.run("HOME='\(root)' PATH='\(bin)':$PATH sh -c \(ShellQuote.quote(ChangeHistory.timelineCommand.replacingOccurrences(of: "sh $HOME/.deckhand/history/snap.sh", with: "ETC='\(etc)' sh $HOME/.deckhand/history/snap.sh")))", timeout: .seconds(60))
        let t = ChangeHistory.parseTimeline(log.stdout)
        #expect(t.installed && !t.cron)
        #expect(t.snapshots.count == 2) // unchanged runs add nothing
        #expect(t.snapshots.last?.isStart == true)
        #expect(t.snapshots.first?.files == ["etc/app/app.conf"])
        let shown = try await shell.run("HOME='\(root)' sh -c \(ShellQuote.quote(ChangeHistory.showCommand(t.snapshots[0].stamp)))", timeout: .seconds(30))
        let files = ChangeHistory.parseDiff(shown.stdout)
        #expect(files.first?.added == ["port = 8080"] && files.first?.removed == ["port = 80"])
        let all = try await shell.run("HOME='\(root)' sh -c \(ShellQuote.quote(ChangeHistory.sinceCommand(Date(timeIntervalSince1970: 1))))", timeout: .seconds(30))
        #expect(!all.stdout.contains("server.key"))
        #expect(all.stdout.contains("+port = 8080") && all.stdout.contains("@@c "))
        _ = try await shell.run("rm -rf '\(root)'", timeout: .seconds(10))
    }
}
