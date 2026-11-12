import Foundation
import Testing
@testable import DeckhandCore

struct ServerCopyTests {
    let target = ServerCopy.Target(host: "web-2.example.com", port: 2222, user: "deploy", hostKey: "ssh-ed25519 AAAAC3Nza comment")

    @Test func commandsPinTheHostKeyAndRestrictTheKey() {
        let prep = ServerCopy.prepareSourceCommand(target: target)
        #expect(prep.contains("'[web-2.example.com]:2222' 'ssh-ed25519 AAAAC3Nza'"))
        let auth = ServerCopy.authorizeCommand(publicKey: "ssh-ed25519 KEYDATA deckhand-transfer", tag: "deckhand-transfer-ab12cd34")
        #expect(auth.contains("no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty ssh-ed25519 KEYDATA deckhand-transfer-ab12cd34"))
        let copy = ServerCopy.copyCommand(source: "~/site", target: target, destination: "/srv/backup", useRsync: true)
        #expect(copy.contains("StrictHostKeyChecking=yes") && copy.contains("--partial") && copy.contains("deploy@web-2.example.com:/srv/backup/"))
        #expect(ServerCopy.tag(UUID(uuidString: "AB12CD34-0000-0000-0000-000000000000")!) == "deckhand-transfer-ab12cd34")
    }

    @Test func progressAndErrors() {
        let out = "sending incremental file list\n      1,048,576  20%  512.00kB/s    0:00:08\n     5,242,880 100%    2.10MB/s    0:00:02 (xfr#2, to-chk=0/3)\n"
        #expect(ServerCopy.progress(out) == .init(percent: 100, bytes: 5_242_880, speed: "2.10MB/s"))
        #expect(ServerCopy.progress("nothing yet") == nil)
        #expect(ServerCopy.explain("Host key verification failed.")?.contains("doesn't match") == true)
        #expect(ServerCopy.explain("ssh: Could not resolve hostname x")?.contains("resolve") == true)
    }
}
