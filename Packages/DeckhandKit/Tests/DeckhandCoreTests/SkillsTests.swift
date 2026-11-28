import Foundation
import Testing
@testable import DeckhandCore

@Suite struct SkillsTests {
    @Test func namesAndFrontMatter() {
        #expect(Skills.isValidName("deploy-helper") && !Skills.isValidName("Deploy") && !Skills.isValidName("a b") && !Skills.isValidName("-x"))
        #expect(Skills.slug("My Deploy Helper!") == "my-deploy-helper")
        let md = Skills.template(name: "deploy-helper", description: "Deploys the \"web\" app\nsafely", body: "1. Pull\n2. Restart\n")
        let fm = Skills.frontMatter(md)
        #expect(fm?.name == "deploy-helper")
        #expect(fm?.description == "Deploys the 'web' app safely")
        #expect(Skills.frontMatter("# no front matter") == nil)
    }

    /// Write, list, copy to the other CLI and remove, in a throwaway HOME on this Mac.
    @Test func installsListsCopiesAndRemoves() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "dh-skills-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let sh = LocalShell()
        func run(_ c: String) async throws -> String { try await sh.run("export HOME='\(home)'; " + c, timeout: .seconds(30)).stdout }

        let md = Skills.template(name: "deploy-helper", description: "Deploys the web app", body: "Run ./deploy.sh")
        #expect(try await run(try #require(Skills.writeCommand(name: "deploy-helper", skillMD: md, targets: [.claude]))).contains("@@ok"))
        var list = Skills.parseList(try await run(Skills.listCommand))
        #expect(list.map(\.name) == ["deploy-helper"])
        #expect(list[0].targets == [.claude] && list[0].description == "Deploys the web app")
        #expect(list[0].path == "~/.claude/skills/deploy-helper")

        _ = try await run(try #require(Skills.copyCommand(name: "deploy-helper", from: .claude, to: .codex)))
        list = Skills.parseList(try await run(Skills.listCommand))
        #expect(list[0].targets == [.claude, .codex])
        #expect(try String(contentsOfFile: home + "/.codex/skills/deploy-helper/SKILL.md", encoding: .utf8) == md)

        _ = try await run(try #require(Skills.removeCommand(name: "deploy-helper", from: .claude)))
        list = Skills.parseList(try await run(Skills.listCommand))
        #expect(list[0].targets == [.codex] && list[0].path == "~/.codex/skills/deploy-helper")
        #expect(Skills.writeCommand(name: "../evil", skillMD: md, targets: [.claude]) == nil)
        #expect(Skills.importGitCommand(url: "file:///etc", targets: [.claude]) == nil)
    }

    @Test func theAgentSeesNamesAndReadsOnDemand() {
        let s = Skills.promptSection([Skills.Skill(name: "deploy-helper", description: "Deploys the web app", targets: [.claude], path: "~/.claude/skills/deploy-helper")])
        #expect(s.contains("deploy-helper: Deploys the web app — ~/.claude/skills/deploy-helper/SKILL.md"))
        #expect(s.contains("read_file"))
        #expect(Skills.promptSection([]).isEmpty)
    }
}

/// Opt-in: DECKHAND_NET_TEST=1. Imports Anthropic's public skills repository into a throwaway HOME.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_NET_TEST"] != nil))
struct SkillsImportLiveTests {
    @Test func importsAPublicRepository() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "dh-skills-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let sh = LocalShell()
        let out = try await sh.run("export HOME='\(home)'; " + (try #require(Skills.importGitCommand(url: "https://github.com/anthropics/skills", targets: [.claude, .codex]))), timeout: .seconds(120)).stdout
        #expect(out.contains("@@ok"), "\(out.suffix(400))")
        let list = Skills.parseList(try await sh.run("export HOME='\(home)'; " + Skills.listCommand, timeout: .seconds(30)).stdout)
        #expect(list.count >= 3)
        #expect(list.allSatisfy { $0.targets == [.claude, .codex] && Skills.isValidName($0.name) })
        #expect(list.contains { !$0.description.isEmpty })
    }
}
