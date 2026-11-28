import Foundation
import Testing
@testable import DeckhandCore

@Suite struct ActionsRunsTests {
    @Test func parsesRunsAndStates() throws {
        let out = #"[{"conclusion":"","createdAt":"2026-11-28T14:20:25Z","databaseId":1,"displayTitle":"Web research","event":"pull_request","headBranch":"feature/x","status":"in_progress","url":"u","workflowName":"CI"},{"conclusion":"failure","createdAt":"2026-11-28T12:00:00Z","databaseId":2,"displayTitle":"Main","event":"push","headBranch":"main","status":"completed","url":"u2","workflowName":"CI"}]"#
        let runs = try #require(ActionsRuns.parseRuns(out))
        #expect(runs.map(\.state) == [.running, .failure])
        #expect(!runs[0].state.isDone && runs[1].state.isDone)
        #expect(ActionsRuns.parseRuns("HTTP 404: Not Found") == nil)
        #expect(ActionsRuns.parseRepos("me/web\nme/api\nnot a repo\n") == ["me/web", "me/api"])
        #expect(ActionsRuns.parseRepos("@@nogh") == nil)
        #expect(ActionsRuns.parseWorkflows("12\tCI\t.github/workflows/ci.yml\tno\n13\tRelease\t.github/workflows/release.yml\tyes\n").map(\.dispatchable) == [false, true])
    }

    @Test func detailAndCommands() throws {
        let jobs = #"{"jobs":[{"name":"Core tests","status":"completed","conclusion":"failure","steps":[{"name":"Checkout","status":"completed","conclusion":"success"},{"name":"swift test","status":"completed","conclusion":"failure"}]}]}"#
        let log = "Core tests\tswift test\t2026-11-28T12:53:50.4925960Z error: exited with signal 13\nCore tests\tswift test\t2026-11-28T12:53:51.0Z ✘ Test run failed"
        let d = try #require(ActionsRuns.parseDetail(jobs + "\n@@log\n" + log))
        #expect(d.jobs.count == 1 && d.jobs[0].failedSteps == ["swift test"])
        #expect(d.log == "error: exited with signal 13\n✘ Test run failed")
        // A long log keeps its error lines and its end.
        let long = (0..<500).map { "line \($0)" } + ["error: build failed at Foo.swift"] + (0..<300).map { "more \($0)" }
        let digest = ActionsRuns.digest(long.joined(separator: "\n"))
        #expect(digest.contains("error: build failed at Foo.swift") && digest.contains("more 299") && !digest.contains("line 10\n"))
        #expect(ActionsRuns.dispatchCommand(repo: "me/web", workflow: 13, ref: "main")?.contains("workflow run 13 -R 'me/web' --ref 'main'") == true)
        #expect(ActionsRuns.dispatchCommand(repo: "me/web", workflow: 13, ref: "a b") == nil)
        #expect(ActionsRuns.rerunCommand(repo: "me/web;x", run: 1) == nil)
        let w = try #require(ActionsRuns.watchCommand(repo: "me/web", run: 9, title: "Main", topicURL: "https://ntfy.sh/abc", onlyFailures: true))
        #expect(w.hasPrefix("nohup sh -c ") && w.contains("run watch 9") && !w.contains("CI passed"))
        #expect(ActionsRuns.watchCommand(repo: "me/web", run: 9, title: "x", topicURL: "http://evil", onlyFailures: true) == nil)
    }
}

/// Opt-in: DECKHAND_NET_TEST=1 with `gh` signed in here. Reads this repository's runs (read only).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_NET_TEST"] != nil))
struct ActionsRunsLiveTests {
    @Test func readsRealRuns() async throws {
        let sh = LocalShell()
        let listCmd = try #require(ActionsRuns.runsCommand(repo: "Riyad-Eita/deckhand", limit: 5))
        let runs = try #require(ActionsRuns.parseRuns(try await sh.run(listCmd, timeout: .seconds(60)).stdout))
        #expect(runs.count == 5 && runs.allSatisfy { $0.workflow == "CI" })
        let wfCmd = try #require(ActionsRuns.workflowsCommand(repo: "Riyad-Eita/deckhand"))
        let wf = ActionsRuns.parseWorkflows(try await sh.run(wfCmd, timeout: .seconds(60)).stdout)
        #expect(wf.contains { $0.name == "CI" })
        // The one failed main run (signal 13) and its digest.
        let detailCmd = try #require(ActionsRuns.detailCommand(repo: "Riyad-Eita/deckhand", run: 46146712132))
        let d = try #require(ActionsRuns.parseDetail(try await sh.run(detailCmd, timeout: .seconds(90)).stdout))
        #expect(d.jobs.contains { $0.state == .failure })
        #expect(d.log.contains("signal code 13"))
    }
}
