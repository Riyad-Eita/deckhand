import DeckhandCore
import Foundation
import Testing
@testable import DeckhandSSH

@Suite struct SSHKeyTests {
    @Test(arguments: ["", "deckhand@test", "deckhand@iphone-of-riad", "x"])
    func generatedKeyRoundTrips(comment: String) throws {
        let pair = SSHKeys.generateEd25519(comment: comment)
        #expect(pair.privateKey.contains("BEGIN OPENSSH PRIVATE KEY"))
        #expect(pair.publicKey.hasPrefix("ssh-ed25519 AAAA"))
        #expect(pair.publicKey.hasSuffix(" \(comment)"))
        #expect(SSHKeys.publicKeyLine(privateKey: pair.privateKey, comment: comment) == pair.publicKey)
        #expect(SSHKeys.fingerprint(openSSHPublicKey: pair.publicKey).hasPrefix("SHA256:"))
    }
}

/// Live test against a real server. Runs only when DECKHAND_TEST_HOST is set, e.g.
/// DECKHAND_TEST_HOST=example.com DECKHAND_TEST_PORT=22 DECKHAND_TEST_USER=me DECKHAND_TEST_KEY=~/.ssh/id_ed25519 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_TEST_HOST"] != nil))
struct LiveSSHTests {
    func connection() async throws -> SSHConnection {
        let env = ProcessInfo.processInfo.environment
        let keyPath = (env["DECKHAND_TEST_KEY"]! as NSString).expandingTildeInPath
        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        let conn = SSHConnection(
            endpoint: SSHEndpoint(host: env["DECKHAND_TEST_HOST"]!, port: Int(env["DECKHAND_TEST_PORT"] ?? "22")!, username: env["DECKHAND_TEST_USER"]!),
            credential: .privateKey(key, passphrase: nil))
        try await conn.connect(pinnedHostKey: nil, trustNewHostKey: { _, _ in true })
        return conn
    }

    @Test func runsCommandsAndReportsExitCodes() async throws {
        let conn = try await connection()
        let ok = try await conn.run("echo hi; echo err >&2", timeout: .seconds(20))
        #expect(ok.stdout == "hi\n")
        #expect(ok.stderr.contains("err"))
        #expect(ok.exitCode == 0)
        let bad = try await conn.run("exit 7", timeout: .seconds(20))
        #expect(bad.exitCode == 7)
        let slow = try await conn.run("sleep 5", timeout: .seconds(1))
        #expect(slow.exitCode == 124)
        #expect(await conn.hostKey != nil)
        await conn.disconnect()
    }

    @Test func serverToolsWorkOverSSH() async throws {
        let conn = try await connection()
        let dir = "/tmp/deckhand-test-\(UUID().uuidString.prefix(8))"
        let tools = ServerTools.all(workingDirectory: dir)
        func tool(_ n: String) -> any AgentTool { tools.first { $0.spec.name == n }! }
        _ = try await tool("write_file").execute(["path": "a/b.txt", "content": "one\n'two' $x\n"], shell: conn)
        let read = try await tool("read_file").execute(["path": "a/b.txt"], shell: conn)
        #expect(read.contains("'two' $x"))
        _ = try await tool("edit_file").execute(["path": "a/b.txt", "old_string": "one", "new_string": "uno"], shell: conn)
        let found = try await tool("search").execute(["pattern": "uno"], shell: conn)
        #expect(found.contains("b.txt"))
        _ = try await conn.run("rm -rf \(dir)", timeout: .seconds(10))
        await conn.disconnect()
    }

    @Test func terminalEchoes() async throws {
        let conn = try await connection()
        let term = try await conn.openTerminal(cols: 80, rows: 24)
        term.send("echo deckhand-$((40+2))\n")
        var seen = ""
        for await chunk in term.output {
            seen += String(decoding: chunk, as: UTF8.self)
            if seen.contains("deckhand-42") { break }
        }
        #expect(seen.contains("deckhand-42"))
        term.close()
        await conn.disconnect()
    }
}
