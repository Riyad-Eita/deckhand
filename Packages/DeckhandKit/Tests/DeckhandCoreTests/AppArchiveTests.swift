import Foundation
import Testing
@testable import DeckhandCore

struct AppArchiveTests {
    let archive = AppArchive(
        created: Date(timeIntervalSince1970: 1_794_400_000),
        servers: [.init(id: UUID(), name: "web", host: "example.com", port: 22, username: "me", authKind: "key", pinnedHostKey: "ssh-ed25519 AAAA",
                        workingDirectory: "~/app", recentDirectories: ["~/app", "/srv"])],
        connections: [.init(id: UUID(), name: "GitHub", kind: "http", url: "https://api.example.com/mcp", command: "", enabled: true)],
        settings: ["provider.kind": .string("anthropic"), "lock.enabled": .bool(true), "lock.delay": .number(60)],
        secrets: ["server.x": "-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----"])

    @Test func roundTrip() throws {
        let data = try archive.sealed(passphrase: "correct horse battery")
        #expect(data.prefix(5) == Data("DHBK1".utf8))
        #expect(!String(decoding: data, as: UTF8.self).contains("example.com")) // encrypted
        #expect(try AppArchive.open(data, passphrase: "correct horse battery") == archive)
    }

    @Test func rejectsWrongPassphraseAndJunk() throws {
        let data = try archive.sealed(passphrase: "one")
        #expect(throws: AppArchive.ArchiveError.wrongPassphrase) { try AppArchive.open(data, passphrase: "two") }
        #expect(throws: AppArchive.ArchiveError.notAnArchive) { try AppArchive.open(Data("hello".utf8), passphrase: "one") }
        var damaged = data; damaged[damaged.count - 1] ^= 0xFF
        #expect(throws: AppArchive.ArchiveError.wrongPassphrase) { try AppArchive.open(damaged, passphrase: "one") }
    }

    @Test func freshSaltEveryTime() throws {
        #expect(try archive.sealed(passphrase: "p") != archive.sealed(passphrase: "p"))
    }
}
