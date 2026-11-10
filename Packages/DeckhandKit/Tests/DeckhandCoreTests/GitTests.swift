import Foundation
import Testing
@testable import DeckhandCore

@Suite(.serialized) struct GitTests {
    let shell = LocalShell()

    func sh(_ cmd: String) async throws -> CommandResult { try await shell.run(cmd, timeout: .seconds(20)) }

    /// A repository with one commit, a bare "remote" and an upstream.
    func makeRepo() async throws -> (repo: String, remote: String) {
        let base = FileManager.default.temporaryDirectory.appending(path: "git-\(UUID().uuidString.prefix(6))").path
        let repo = base + "/app", remote = base + "/remote.git"
        _ = try await sh("""
        set -e; mkdir -p '\(repo)'; git init -q --bare '\(remote)'; cd '\(repo)'; git init -q -b main
        git config user.name 'Test'; git config user.email 'test@example.com'
        printf 'one\\ntwo\\n' > notes.txt; printf 'x\\n' > 'with space.txt'; git add -A; git commit -q -m 'First'
        git remote add origin '\(remote)'; git push -q -u origin main
        """)
        return (repo, remote)
    }

    @Test func statusDiffStageCommitPush() async throws {
        let (repo, remote) = try await makeRepo()
        _ = try await sh("cd '\(repo)' && printf 'one\\nTWO\\n' > notes.txt && echo new > added.txt && rm 'with space.txt'")
        var status = Git.parseStatus(try await sh(Git.statusCommand(repo)).stdout)
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(Set(status.files.map(\.path)) == ["notes.txt", "added.txt", "with space.txt"])
        #expect(status.files.first { $0.path == "added.txt" }?.unstaged == .untracked)
        #expect(status.files.first { $0.path == "with space.txt" }?.unstaged == .deleted)

        let notes = status.files.first { $0.path == "notes.txt" }!
        let diff = try await sh(Git.diffCommand(repo, file: notes, staged: false)).stdout
        #expect(diff.contains("-two") && diff.contains("+TWO"))
        let newFile = try await sh(Git.diffCommand(repo, file: status.files.first { $0.path == "added.txt" }!, staged: false)).stdout
        #expect(newFile.contains("+new"))

        _ = try await sh(Git.stageCommand(repo, paths: ["notes.txt", "with space.txt"]))
        status = Git.parseStatus(try await sh(Git.statusCommand(repo)).stdout)
        #expect(Set(status.staged.map(\.path)) == ["notes.txt", "with space.txt"])
        #expect(try await sh(Git.diffCommand(repo, file: notes, staged: true)).stdout.contains("+TWO"))
        _ = try await sh(Git.unstageCommand(repo, paths: ["with space.txt"]))
        #expect(Git.parseStatus(try await sh(Git.statusCommand(repo)).stdout).staged.map(\.path) == ["notes.txt"])

        #expect(try await sh(Git.stagedDiffForMessage(repo)).stdout.contains("notes.txt"))
        let commit = try await sh(Git.commitCommand(repo, message: "Shout the second line\n\nBecause it's important."))
        #expect(commit.exitCode == 0 && commit.stdout.contains("Shout the second line"))
        status = Git.parseStatus(try await sh(Git.statusCommand(repo)).stdout)
        #expect(status.ahead == 1)

        let push = try await sh(Git.pushCommand(repo))
        #expect(push.exitCode == 0)
        #expect(try await sh("git --git-dir='\(remote)' log -1 --format=%s main").stdout == "Shout the second line\n")
        #expect(Git.parseLog(try await sh(Git.logCommand(repo)).stdout).map(\.subject) == ["Shout the second line", "First"])
    }

    @Test func branchesAndFirstPushOfANewBranch() async throws {
        let (repo, remote) = try await makeRepo()
        #expect(try await sh(Git.switchCommand(repo, branch: "feature/login", create: true)).exitCode == 0)
        let branches = Git.parseBranches(try await sh(Git.branchesCommand(repo)).stdout)
        #expect(branches.first { $0.isCurrent }?.name == "feature/login")
        #expect(branches.first { $0.name == "main" }?.upstream == "origin/main")
        _ = try await sh("cd '\(repo)' && echo hi > hi.txt && git add hi.txt && git commit -q -m Hi")
        #expect(try await sh(Git.pushCommand(repo)).exitCode == 0)
        #expect(try await sh("git --git-dir='\(remote)' branch --list 'feature/login'").stdout.contains("feature/login"))
        #expect(Git.isValidBranchName("feature/login") && !Git.isValidBranchName("bad..name") && !Git.isValidBranchName("-x"))
    }

    @Test func discardAndHints() async throws {
        let (repo, _) = try await makeRepo()
        _ = try await sh("cd '\(repo)' && echo changed > notes.txt && echo tmp > tmp.txt")
        let status = Git.parseStatus(try await sh(Git.statusCommand(repo)).stdout)
        for f in status.files { _ = try await sh(Git.discardCommand(repo, file: f)) }
        #expect(Git.parseStatus(try await sh(Git.statusCommand(repo)).stdout).isClean)
        #expect(Git.hint(for: "fatal: could not read Username for 'https://github.com': terminal prompts disabled") != nil)
        #expect(Git.hint(for: "*** Please tell me who you are.") != nil)
    }
}
