import Foundation
import Testing
@testable import DeckhandCore

@Suite struct KeyInstallTests {
    @Test func installsOnceWithSafePermissions() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "ki-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnlyForTests deckhand@test"
        let cmd = "HOME='\(home)' sh -c \(ShellQuote.quote(KeyInstall.command(publicKey: key)))"
        let first = try await LocalShell().run(cmd, timeout: .seconds(10))
        #expect(KeyInstall.succeeded(first))
        _ = try await LocalShell().run(cmd, timeout: .seconds(10))
        let content = try String(contentsOfFile: home + "/.ssh/authorized_keys", encoding: .utf8)
        #expect(content == key + "\n")
        let dir = try FileManager.default.attributesOfItem(atPath: home + "/.ssh")[.posixPermissions] as? Int
        let file = try FileManager.default.attributesOfItem(atPath: home + "/.ssh/authorized_keys")[.posixPermissions] as? Int
        #expect(dir == 0o700)
        #expect(file == 0o600)
    }

    @Test func keepsExistingKeys() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "ki-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        try "ssh-rsa AAAAold me@laptop\n".write(toFile: home + "/.ssh/authorized_keys", atomically: true, encoding: .utf8)
        let cmd = "HOME='\(home)' sh -c \(ShellQuote.quote(KeyInstall.command(publicKey: "ssh-ed25519 AAAAnew deckhand")))"
        _ = try await LocalShell().run(cmd, timeout: .seconds(10))
        let content = try String(contentsOfFile: home + "/.ssh/authorized_keys", encoding: .utf8)
        #expect(content == "ssh-rsa AAAAold me@laptop\nssh-ed25519 AAAAnew deckhand\n")
    }
}
