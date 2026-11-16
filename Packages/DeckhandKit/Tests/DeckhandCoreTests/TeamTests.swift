import Foundation
import Testing
@testable import DeckhandCore

struct TeamTests {
    let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOnetimeonetimeonetimeonetimeonetimeone"
    let id = "a1b2c3d4e5f6"
    var until: Date { Date().addingTimeInterval(86_400) }

    @Test func acceptScriptIsTheOneInPairSh() throws {
        let text = try String(contentsOf: PairingTests.script, encoding: .utf8)
        #expect(text.contains("<<'ACCEPT'\n" + Team.acceptScript + "\nACCEPT\n"))
    }

    @Test func userNames() {
        #expect(Team.suggestedUser(for: "Anna Müller") == "anna")
        #expect(Team.suggestedUser(for: "Émile") == "emile")
        #expect(Team.suggestedUser(for: "42 Bot") == "u42")
        #expect(Team.isValidUser("anna") && Team.isValidUser("dev_2"))
        #expect(!Team.isValidUser("root") && !Team.isValidUser("Anna") && !Team.isValidUser("a;b") && !Team.isValidUser("-x"))
    }

    @Test func scriptsRefuseBadInputAndAreValidShell() throws {
        var m = Team.Member(user: "anna", person: "Anna: \"Ops\"", role: .developer, groups: ["docker", "bad group"],
                            folders: ["/srv/app", "/", "/srv/../etc"], expires: Date(timeIntervalSince1970: 1_800_000_000), inviteUntil: until)
        let invite = Team.inviteScript(m, oneTimePublicKey: key, id: id)
        #expect(invite.contains("usermod -aG docker"))
        #expect(!invite.contains("bad group"))
        #expect(invite.contains("'/srv/app'") && !invite.contains("'/'") && !invite.contains(".."))
        #expect(invite.contains("-e 2027-01-15"))
        #expect(!invite.contains("sudoers"), "a developer gets no sudo")
        #expect(Team.inviteScript(m, oneTimePublicKey: key + " ; rm -rf /", id: id).contains("@@failed"))
        #expect(Team.inviteScript(m, oneTimePublicKey: key, id: "zz").contains("@@failed"))
        var bad = m; bad.user = "root"
        #expect(Team.inviteScript(bad, oneTimePublicKey: key, id: id).contains("@@failed"))
        var admin = m; admin.role = .admin
        let a = Team.inviteScript(Team.Member(user: "anna", person: "Anna", role: .admin, inviteUntil: until), oneTimePublicKey: key, id: id)
        #expect(a.contains("NOPASSWD:ALL") && a.contains("visudo -cf"))
        m.role = .readOnly
        for script in [invite, a, Team.changeScript(from: admin, to: m), Team.removeScript(admin), Team.statusScript(users: ["anna", "x;y"]),
                       Team.shareOwnAccessCommand(oneTimePublicKey: key, id: id, until: until)] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n", "-c", script]
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(script)")
        }
        #expect(!Team.statusScript(users: ["anna", "x;y"]).contains("x;y"))
        #expect(Team.removeScript(admin).contains("'Deckhand - '*)"), "only accounts Deckhand made are removed")
    }

    @Test func linkRoundTrip() throws {
        let code = Pairing.Code(host: "203.0.113.7", port: 2222, user: "anna", name: "web 1", seed: Data((0..<32).map { UInt8($0) }),
                                fingerprints: ["SHA256:uY8m3vC1fLhQm0rXH2k2s9K5yJ3nYb7wq0PZcV4tA1E"], expires: Date(timeIntervalSince1970: 1_800_000_000))
        let back = try #require(Pairing.parse(URL(string: Pairing.link(code))!))
        #expect(back == code)
    }

    @Test func recordsAndStatus() {
        let m = Team.Member(user: "anna", person: "Anna", role: .developer, groups: ["docker"], folders: ["/srv/app"],
                            invited: Date(timeIntervalSince1970: 1_794_800_000), inviteUntil: Date(timeIntervalSince1970: 1_794_886_400))
        let save = Team.saveCommand(m)
        let json = String(save[save.range(of: "printf '%s\\n' '")!.upperBound...].prefix { $0 != "'" })
        let members = Team.parseRecords("@@member \(json)\n@@member {broken\n")
        #expect(members == [m])
        let entries = Team.entries(members + [Team.Member(user: "ben", person: "Ben", role: .admin, inviteUntil: Date(timeIntervalSince1970: 1))],
                                   status: "@@status anna 1 0 1794810000\n@@status ben 1 1 0\n")
        #expect(entries[0].state(now: Date(timeIntervalSince1970: 1_794_900_000)) == .active)
        #expect(entries[0].lastLogin == Date(timeIntervalSince1970: 1_794_810_000))
        #expect(entries[1].state(now: Date(timeIntervalSince1970: 2)) == .inviteExpired)
        #expect(Team.entries(members, status: "@@status anna 0 0 0").first?.state() == .removed)
    }

    /// "Share my own access" in a temporary home, then the one-time key's forced command: one key, once.
    @Test func shareOwnAccessThenAccept() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dh-team-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func sh(_ script: String, env: [String: String] = [:]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", script]
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"].merging(env) { $1 }
            let out = Pipe(); p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(try sh(Team.shareOwnAccessCommand(oneTimePublicKey: key, id: id, until: until)).contains("@@invited"))
        let ak = try String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8)
        #expect(ak.hasPrefix("restrict,command=\"/bin/sh \(home.path)/.deckhand/pair/accept.sh \(id)\""))
        #expect(ak.hasSuffix(" deckhand-pair-\(id)\n"))
        let phone = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPhonekeyphonekeyphonekeyphonekeyphoneke deckhand Anna"
        #expect(try sh("sh ~/.deckhand/pair/accept.sh \(id)", env: ["SSH_ORIGINAL_COMMAND": phone]).contains("@@paired"))
        #expect(try String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8) == phone + "\n")
    }
}
