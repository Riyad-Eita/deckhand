import Foundation
import Testing
@testable import DeckhandCore

struct AuthorizedKeysTests {
    static let a = Data((0..<51).map { UInt8($0) }).base64EncodedString()
    static let b = Data((0..<51).map { UInt8(255 - $0) }).base64EncodedString()
    static let c = Data((0..<279).map { UInt8($0 % 251) }).base64EncodedString()
    static let file = """
    # my keys
    ssh-ed25519 \(a) deckhand@Riads-iPhone
    from="10.0.0.0/8",no-agent-forwarding ssh-ed25519 \(b) deckhand@Old iPhone

    ssh-rsa \(c) laptop
    """

    @Test func parses() {
        let keys = AuthorizedKeys.parse(Self.file)
        #expect(keys.map(\.comment) == ["deckhand@Riads-iPhone", "deckhand@Old iPhone", "laptop"])
        #expect(keys[1].type == "ssh-ed25519" && keys[1].blob == Self.b)
        #expect(keys[0].fingerprint.hasPrefix("SHA256:") && keys[0].fingerprint != keys[1].fingerprint)
        #expect(AuthorizedKeys.blob(ofPublicKey: "ssh-ed25519 \(Self.a) x") == Self.a)
    }

    @Test func removesOnlyTheGivenKeys() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "ak-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        try Self.file.write(toFile: home + "/.ssh/authorized_keys", atomically: true, encoding: .utf8)
        let cmd = try #require(AuthorizedKeys.removeCommand(blobs: [Self.b]))
        let r = try await LocalShell().run("HOME='\(home)' /bin/sh -c \(ShellQuote.quote(cmd))", timeout: .seconds(10))
        #expect(r.stdout.contains("@@left 2"))
        let left = AuthorizedKeys.parse(try String(contentsOfFile: home + "/.ssh/authorized_keys", encoding: .utf8))
        #expect(left.map(\.blob) == [Self.a, Self.c])
        #expect(FileManager.default.fileExists(atPath: home + "/.ssh/authorized_keys.deckhand-bak"))
        #expect(AuthorizedKeys.removeCommand(blobs: ["x; rm -rf ~"]) == nil)
    }
}
