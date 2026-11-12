import Foundation
import Testing
@testable import DeckhandCore

struct HostImportTests {
    @Test func sshConfig() {
        let config = """
        # work
        Host web-1 web-1-alias
            HostName 203.0.113.10
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_work_ed25519

        Host db
          HostName=db.example.com
          ProxyJump web-1

        Host *.internal
          User admin

        Match host foo
          User nobody

        Host *
          User me
          IdentityFile ~/.ssh/id_ed25519
        """
        let c = HostImport.parseSSHConfig(config)
        #expect(c.map(\.name) == ["web-1", "web-1-alias", "db"])
        #expect(c[0] == HostImport.Candidate(name: "web-1", host: "203.0.113.10", port: 2222, user: "deploy", identityFile: "id_work_ed25519"))
        #expect(c[2].host == "db.example.com" && c[2].user == "admin" && c[2].identityFile == "id_ed25519")   // first wildcard default wins
        #expect(HostImport.parse(config).count == 3)
    }

    @Test func csvExports() {
        let csv = """
        Label;Hostname;Port;Username
        "Shop; prod";shop.example.com;22;deploy
        Home lab;192.168.1.20;;pi
        ;;;
        """
        let c = HostImport.parse(csv)
        #expect(c.count == 2 && c[0].name == "Shop; prod" && c[0].user == "deploy" && c[1].port == 22 && c[1].user == "pi")
        #expect(HostImport.parseCSV("name,notes\nx,y").isEmpty)                            // no host column
    }

    @Test func keysAndDuplicates() {
        #expect(HostImport.isPrivateKey("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"))
        #expect(!HostImport.isPrivateKey("ssh-ed25519 AAAA me@mac"))
        let c = HostImport.Candidate(name: "web", host: "Web.Example.com", port: 22, user: "deploy")
        #expect(HostImport.isDuplicate(c, of: [("web.example.com", 22, "deploy")]))
        #expect(!HostImport.isDuplicate(c, of: [("web.example.com", 2222, "deploy")]))
    }
}
