import Foundation
import Testing
@testable import DeckhandCore

@Suite struct SecretsTests {
    func hidden(_ text: String) -> [String] {
        let ns = text as NSString
        return Secrets.find(in: text).map { ns.substring(with: $0.range) }
    }

    // Built at runtime so the test file itself doesn't look like it contains real keys.
    static let gh = "ghp_" + String(repeating: "a1B2", count: 9)
    static let openai = "sk-proj-" + String(repeating: "Xy9_", count: 8)
    static let anthropic = "sk-ant-api03-" + String(repeating: "Qw3-", count: 10)
    static let aws = "AKIA" + "ABCDEFGHIJKLMNOP"

    @Test func knownTokenFormats() {
        #expect(hidden("token \(Self.gh) here") == [Self.gh])
        #expect(hidden("OPENAI=\(Self.openai)") == [Self.openai])
        #expect(Secrets.find(in: "key: \(Self.anthropic)").map(\.kind) == ["Anthropic key"])
        #expect(hidden("aws \(Self.aws) x") == [Self.aws])
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(hidden("Bearer \(jwt)") == [jwt])
    }

    @Test func privateKeyBlocks() {
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\nAAAA\n-----END OPENSSH PRIVATE KEY-----"
        let text = "id_ed25519:\n\(key)\ndone"
        #expect(hidden(text) == [key])
        #expect(Secrets.mask(text) == "id_ed25519:\n••••••••\ndone")
    }

    @Test func assignmentsMaskOnlyTheValue() {
        #expect(hidden("DB_PASSWORD=hunter2hunter") == ["hunter2hunter"])
        #expect(hidden("export GITHUB_TOKEN=\"abcdef123456\"") == ["abcdef123456"])
        #expect(hidden("  api_key: sk_test_123456789") == ["sk_test_123456789"])
        #expect(hidden(#"{"client_secret": "s3cr3t-value", "name": "x"}"#) == ["s3cr3t-value"])
        #expect(hidden("Authorization: Bearer abc.def.ghi-123") == ["abc.def.ghi-123"])
        #expect(hidden("postgres://app:Sup3rS3cret@db:5432/app") == ["Sup3rS3cret"])
    }

    @Test func leavesSettingsAndPlaceholdersAlone() {
        #expect(hidden("PASSWORD_MIN_LENGTH=12").isEmpty)
        #expect(hidden("DB_PASSWORD=${DB_PASSWORD}").isEmpty)
        #expect(hidden("token: ********").isEmpty)
        #expect(hidden("password: changeme").isEmpty)
        #expect(hidden("auth_enabled=true").isEmpty)
        #expect(hidden("TOKEN_TTL=3600").isEmpty)
        #expect(hidden("ls -la /etc/passwd").isEmpty)
        #expect(hidden("https://example.com/path?q=1").isEmpty)
        #expect(hidden("git@github.com:me/app.git").isEmpty)
        #expect(hidden("The tokenizer splits words").isEmpty)
    }

    @Test func redactsForTheModel() {
        let text = "GITHUB_TOKEN=\(Self.gh)\nAWS=\(Self.aws)\nok"
        let r = Secrets.redact(text)
        #expect(!r.contains(Self.gh) && !r.contains(Self.aws))
        #expect(r.contains("[REDACTED: GitHub token]") || r.contains("[REDACTED: secret]"))
        #expect(r.hasSuffix("\nok"))
        // Already redacted text stays as it is.
        #expect(Secrets.redact(r) == r)
    }

    @Test func overlappingPatternsBecomeOne() {
        // The token both matches the GitHub pattern and the TOKEN= assignment.
        #expect(Secrets.find(in: "GH_TOKEN=\(Self.gh)").count == 1)
    }
}
