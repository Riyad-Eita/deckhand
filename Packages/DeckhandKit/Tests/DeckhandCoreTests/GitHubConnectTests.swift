import Testing
@testable import DeckhandCore

struct GitHubConnectTests {
    @Test func status() {
        #expect(GitHubConnect.parseStatus("@@nogh\n") == .notInstalled)
        #expect(GitHubConnect.parseStatus("You are not logged into any GitHub hosts. To log in, run: gh auth login") == .signedOut)
        #expect(GitHubConnect.parseStatus("""
        github.com
          ✓ Logged in to github.com account octocat (/home/me/.config/gh/hosts.yml)
          - Active account: true
        """) == .signedIn(account: "octocat"))
        #expect(GitHubConnect.parseStatus("  ✓ Logged in to github.com as old-style (oauth_token)") == .signedIn(account: "old-style"))
    }

    @Test func loginOutput() {
        #expect(GitHubConnect.event("! First copy your one-time code: 32B1-D7CE") == .code("32B1-D7CE"))
        #expect(GitHubConnect.event("! One-time code (AB12-CD34) copied to clipboard") == .code("AB12-CD34"))
        #expect(GitHubConnect.event("Open this URL to continue in your web browser: https://github.com/login/device") == nil)
        #expect(GitHubConnect.event("@@ok") == .succeeded)
        if case .failed? = GitHubConnect.event("@@failed") {} else { Issue.record("no failure") }
    }

    /// Without a GitHub CLI on the PATH the status says so.
    @Test func statusWithoutGh() async throws {
        let r = try await LocalShell().run("HOME=/nonexistent PATH=/usr/bin:/bin /bin/sh -c \(ShellQuote.quote(GitHubConnect.statusCommand))", timeout: .seconds(10))
        #expect(GitHubConnect.parseStatus(r.stdout) == .notInstalled)
    }
}
