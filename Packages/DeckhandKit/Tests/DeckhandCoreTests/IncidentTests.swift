import Foundation
import Testing
@testable import DeckhandCore

struct IncidentTests {
    @Test func parsesSections() {
        let out = "noise\n@@section Request\nHTTP 502 after 0.1s\n\n@@section Disk\n\n@@section Failed services\nnginx.service failed\n"
        let e = Incident.parse(out)
        #expect(e.map(\.title) == ["Request", "Failed services"])
        #expect(e[0].text == "HTTP 502 after 0.1s")
    }

    @Test func promptHasEvidenceAndFixShape() {
        var c = Uptime.Check(id: "a1", name: "Shop", url: "https://shop.example.com", expect: "200", keyword: "Cart")
        c.results = [
            .init(date: Date(timeIntervalSince1970: 100), status: 200, milliseconds: 80, ok: true),
            .init(date: Date(timeIntervalSince1970: 160), status: 502, milliseconds: 12, ok: false),
            .init(date: Date(timeIntervalSince1970: 220), status: 502, milliseconds: 11, ok: false),
        ]
        #expect(c.downSince == Date(timeIntervalSince1970: 160))
        let p = Incident.prompt(check: c, evidence: [.init(title: "Failed services", text: "nginx.service failed")])
        #expect(p.contains("HTTP 502 after 11 ms"))
        #expect(p.contains("### Failed services\n```\nnginx.service failed\n```"))
        #expect(p.contains("## Suggested fix"))
        #expect(p.contains("the text \"Cart\""))
        #expect(p.contains("Don't change anything yet"))
    }

    @Test func findsSuggestedFix() {
        let reply = """
        nginx stopped after the config change at 10:02 (`unknown directive "gzipp"`).

        ## Suggested fix
        Fix the typo and reload:
        ```sh
        sudo sed -i 's/gzipp/gzip/' /etc/nginx/nginx.conf
        sudo nginx -t && sudo systemctl restart nginx
        ```
        """
        #expect(Incident.suggestedFix(in: reply) == "sudo sed -i 's/gzipp/gzip/' /etc/nginx/nginx.conf\nsudo nginx -t && sudo systemctl restart nginx")
        #expect(Incident.suggestedFix(in: "All good.\n```sh\nls\n```") == nil)
        #expect(Incident.suggestedFix(in: "## Suggested fix\nNone needed, the outage was upstream.") == nil)
    }

    @Test func changesSectionBecomesReadable() {
        let out = "@@section Changed since last healthy\n@@c 1794390732 1794390732 snapshot|pkg apt-get upgrade\nM\tpackages.txt\ndiff -rN -U0 state/packages.txt next/packages.txt\n-nginx 1.24\n+nginx 1.26\n"
        let e = Incident.parse(out)
        #expect(e.first?.text == "packages: nginx 1.24 → 1.26")
    }

    @Test func evidenceProbeRunsLocally() async throws {
        let r = try await LocalShell().run(Incident.evidenceCommand(url: "http://127.0.0.1:9/"), timeout: .seconds(60))
        let e = Incident.parse(r.stdout)
        #expect(e.first?.title == "Request")
        #expect(e.first?.text.contains("HTTP 000") == true)
        #expect(e.contains { $0.title == "Load and memory" })
    }

    @Test func findsSuggestedCheck() {
        let reply = """
        It's up again.

        ```check
        name: Shop database
        url: https://shop.example.com/health/db
        expect: 200
        keyword: "ok"
        ```
        """
        let c = Incident.suggestedCheck(in: reply)
        #expect(c?.name == "Shop database" && c?.url == "https://shop.example.com/health/db" && c?.expect == "200" && c?.keyword == "ok")
        #expect(Incident.suggestedCheck(in: "```check\nurl: ftp://x\n```") == nil)
        #expect(Incident.suggestedCheck(in: "```check\nurl: https://a.example.com\n```")?.expect == "200-399")
        #expect(Incident.applyPrompt.contains("```check"))
    }
}
