import Foundation
import Testing
@testable import DeckhandCore

struct BackupsTests {
    @Test func setupWritesEverything() {
        var p = Backups.Plan(paths: ["/home/me", " /srv/app "], target: .s3(endpoint: "https://s3.example.com/", bucket: "my-backups", accessKey: "AK", secretKey: "S'K"), password: "pw-1")
        p.hour = 4; p.topic = "https://ntfy.sh/x"
        let c = Backups.setupCommand(p)
        let env = Backups.envFile(p)
        #expect(env.contains("RESTIC_REPOSITORY='s3:https://s3.example.com/my-backups'"))
        #expect(env.contains("AWS_SECRET_ACCESS_KEY='S'\\''K'"))
        #expect(env.contains("RESTIC_PASSWORD_FILE=\"$HOME/.deckhand/backup/password\""))
        #expect(c.contains("/home/me\n/srv/app") || c.contains("'/home/me\n/srv/app'"))
        #expect(c.contains(" 4 * * * $HOME/.deckhand/backup/run.sh"))
        #expect(c.contains("restic_0.17.3_linux_$A.bz2"))
        #expect(Backups.Target.folder("/mnt/backup").repository == "/mnt/backup")
        #expect(Backups.Target.sftp("me@nas.example.com:/backups").repository == "sftp:me@nas.example.com:/backups")
        #expect(Backups.newPassword().split(separator: "-").count == 6)
        let local = Backups.Plan(paths: ["/home/me"], target: .folder("/home/me/repo"), password: "x")
        #expect(Backups.excludes(local).last == "/home/me/repo")
    }

    @Test func parsesStatusAndSnapshots() {
        let out = """
        @@configured
        @@repo /home/me/backup-repo
        @@keep 7 4 6
        @@path /home/me
        @@cron 17 3
        @@run 1794390000 1794390042 1
        @@run 1794476400 1794476401 0
        @@snapshots [{"time":"2026-11-11T03:17:02.123456789+01:00","tree":"ab","paths":["/home/me"],"hostname":"web1","username":"me","id":"4f1c2d3e4f5a6b7c8d9e","short_id":"4f1c2d3e","summary":{"data_added":1048576,"total_bytes_processed":52428800}},{"time":"2026-11-10T03:17:01Z","paths":["/home/me"],"id":"aaaabbbbcccc","short_id":"aaaabbbb"}]
        """
        let s = Backups.parseStatus(out)
        #expect(s.configured && s.repository == "/home/me/backup-repo" && s.keep.daily == 7)
        #expect(s.schedule?.hour == 3 && s.schedule?.minute == 17)
        #expect(s.runs.count == 2 && s.lastRun?.ok == false)
        #expect(s.snapshots.map(\.shortID) == ["4f1c2d3e", "aaaabbbb"])
        #expect(s.snapshots[0].addedBytes == 1_048_576 && s.snapshots[0].totalBytes == 52_428_800)
        #expect(abs(s.snapshots[0].time.timeIntervalSince1970 - 1_794_363_422) < 1)
        #expect(Backups.parseStatus("@@missing").configured == false)
    }

    @Test func listsOneFolder() {
        let out = """
        {"time":"2026-11-11T03:17:02Z","paths":["/home/me"],"id":"4f1c","struct_type":"snapshot"}
        {"name":"app","type":"dir","path":"/home/me/app","struct_type":"node"}
        {"name":"notes.txt","type":"file","path":"/home/me/notes.txt","size":120,"struct_type":"node"}
        {"name":"deep.txt","type":"file","path":"/home/me/app/deep.txt","size":5,"struct_type":"node"}
        """
        let n = Backups.parseList(out, parent: "/home/me")
        #expect(n.map(\.name) == ["app", "notes.txt"])
        #expect(n[0].isDirectory && n[1].size == 120)
    }

    @Test func restoreGoesToANewFolder() {
        let c = Backups.restoreCommand(snapshot: "4f1c2d3e; rm -rf /", path: "/home/me/notes.txt", date: Date(timeIntervalSince1970: 1_794_363_422))
        #expect(c.contains("restore '4f1c2d3ed' --include '/home/me/notes.txt'") || c.contains("restore '4f1c2d3e"))
        #expect(!c.contains("rm -rf /'"))
        #expect(c.contains("T=\"$HOME/restored-"))
    }
}
