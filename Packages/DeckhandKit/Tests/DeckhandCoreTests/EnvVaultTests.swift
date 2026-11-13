import Foundation
import Testing
@testable import DeckhandCore

struct EnvVaultTests {
    let text = """
    # Shop settings
    DATABASE_URL=postgres://app:secret@localhost/shop
    export STRIPE_KEY="sk_live_with space"
    GREETING='hello # not a comment'

    not a variable line
    """

    @Test func parseAndWriteBack() {
        let lines = EnvVault.parse(text)
        #expect(EnvVault.variables(lines).map(\.key) == ["DATABASE_URL", "STRIPE_KEY", "GREETING"])
        #expect(EnvVault.variables(lines)[1].value == "sk_live_with space")
        #expect(EnvVault.serialize(lines) == text + "\n")                       // unchanged lines come back as they were
    }

    @Test func setAndRemove() {
        var lines = EnvVault.parse(text)
        lines = EnvVault.set("STRIPE_KEY", "sk_new", in: lines)
        lines = EnvVault.set("NEW_ONE", "a b", in: lines)
        lines = EnvVault.remove("GREETING", from: lines)
        let out = EnvVault.serialize(lines)
        #expect(out.contains(#"export STRIPE_KEY="sk_new""#) && out.contains(#"NEW_ONE="a b""#) && !out.contains("GREETING"))
        #expect(out.hasPrefix("# Shop settings\n") && out.contains("not a variable line"))
    }

    @Test func historyIsCapped() {
        var f = EnvVault.File(path: "~/shop/.env", versions: [], lastKnownHash: "")
        for i in 0..<40 { f.add(.init(content: "A=\(i)\n", note: "Edited")) }
        #expect(f.versions.count == EnvVault.File.keep && f.current?.content == "A=39\n")
        #expect(EnvVault.hash("A=1\n") == EnvVault.hash("A=1\n") && EnvVault.hash("A=1\n") != EnvVault.hash("A=2\n"))
    }

    @Test func pathsAndReads() {
        #expect(EnvVault.isValidPath("~/shop/.env") && EnvVault.isValidPath("/srv/app/.env.production"))
        #expect(!EnvVault.isValidPath("~/x/../../etc/passwd") && !EnvVault.isValidPath("~/a;rm") && !EnvVault.isValidPath("~/dir/"))
        let r = EnvVault.parseRead("@@mode 600\n@@content\nA=1\n")
        #expect(r.exists && r.mode == "600" && r.content == "A=1\n")
        #expect(!EnvVault.parseRead("@@missing\n").exists)
    }
}
