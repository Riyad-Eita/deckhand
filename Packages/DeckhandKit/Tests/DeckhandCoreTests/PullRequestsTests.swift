import Foundation
import Testing
@testable import DeckhandCore

@Suite struct PullRequestsTests {
    @Test func parsesTheListReviewRequestsFirst() {
        let r = #"[{"number":7,"title":"Fix login","repository":{"nameWithOwner":"me/web"},"author":{"login":"ann"},"updatedAt":"2026-11-20T10:00:00Z","url":"https://github.com/me/web/pull/7","isDraft":false}]"#
        let m = #"[{"number":3,"title":"My change","repository":{"nameWithOwner":"me/api"},"author":{"login":"me"},"updatedAt":"2026-11-27T10:00:00Z","url":"u","isDraft":true}]"#
        let l = PullRequests.parseList("R\t\(r)\nM\t\(m)\n")
        #expect(l.items.map(\.id) == ["me/web#7", "me/api#3"])
        #expect(l.items[0].reviewRequested && !l.items[1].reviewRequested && l.items[1].isDraft)
        #expect(PullRequests.parseList("@@nogh").noGH)
        #expect(PullRequests.parseList("R\tTo get started with GitHub CLI, please run: gh auth login\n").error?.contains("gh auth login") == true)
    }

    @Test func parsesDetailAndReview() throws {
        let json = #"{"title":"Fix login","body":"Fixes #1","author":{"login":"ann"},"baseRefName":"main","headRefName":"fix","additions":10,"deletions":2,"files":[{"path":"a.swift","additions":10,"deletions":2}],"mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"FAILURE"},{"status":"IN_PROGRESS"}]}"#
        let d = try #require(PullRequests.parseDetail(json + "\n@@diff\ndiff --git a/a.swift b/a.swift\n+x\n"))
        #expect(d.title == "Fix login" && d.files.count == 1 && d.files[0].path == "a.swift")
        #expect(d.checks == (1, 1, 1))
        #expect(d.diff.hasPrefix("diff --git"))
        let p = PullRequests.reviewPrompt(d, budget: 300)
        #expect(p.contains("a.swift (+10 −2)") && p.count <= 420)
        let review = PullRequests.parseReview("SUMMARY: Fixes the login redirect.\nRISKS:\n- a.swift: session cookie now lax\n- none found")
        #expect(review.summary == "Fixes the login redirect." && review.risks == ["a.swift: session cookie now lax"])
        #expect(PullRequests.parseDetail("no marker") == nil)
    }

    @Test func actionsAreQuotedAndChecked() {
        #expect(PullRequests.reviewCommand(repo: "me/web", number: 7, verdict: .approve, body: "")?.contains("pr review 7 -R 'me/web' --approve 2>&1") == true)
        #expect(PullRequests.reviewCommand(repo: "me/web", number: 7, verdict: .comment, body: "") == nil)
        #expect(PullRequests.reviewCommand(repo: "me/web", number: 7, verdict: .requestChanges, body: "it's wrong")?.contains("--request-changes -b 'it'\\''s wrong'") == true)
        #expect(PullRequests.mergeCommand(repo: "me/web", number: 7, method: .squash, deleteBranch: true)?.contains("--squash --delete-branch") == true)
        #expect(PullRequests.mergeCommand(repo: "me/../x", number: 7, method: .squash, deleteBranch: false) == nil)
        #expect(PullRequests.detailCommand(repo: "me/web; rm -rf /", number: 1) == nil)
    }
}

/// Opt-in: DECKHAND_NET_TEST=1 with `gh` signed in on this Mac. Reads a public PR (read only).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DECKHAND_NET_TEST"] != nil))
struct PullRequestsLiveTests {
    @Test func readsARealPullRequest() async throws {
        let out = try await LocalShell().run(try #require(PullRequests.detailCommand(repo: "Riyad-Eita/deckhand", number: 382)), timeout: .seconds(60)).stdout
        let d = try #require(PullRequests.parseDetail(out), "\(out.prefix(300))")
        #expect(d.title.contains("Claude Code"))
        #expect(d.files.contains { $0.path.hasSuffix("PermissionPrompt.swift") })
        #expect(d.diff.contains("diff --git"))
        let list = PullRequests.parseList(try await LocalShell().run(PullRequests.listCommand, timeout: .seconds(60)).stdout)
        #expect(list.error == nil && !list.noGH)
    }
}
