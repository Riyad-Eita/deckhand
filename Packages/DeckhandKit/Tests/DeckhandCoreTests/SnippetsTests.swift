import Foundation
import Testing
@testable import DeckhandCore

@Suite struct SnippetsTests {
    @Test func placeholders() {
        let s = Snippet(title: "Logs", command: "journalctl -u {{service}} -n {{lines:200}} --since '{{ since : 1 hour ago}}' | grep {{service}}")
        #expect(s.placeholders.map(\.name) == ["service", "lines", "since"])
        #expect(s.placeholders.map(\.defaultValue) == ["", "200", "1 hour ago"])
        #expect(s.filled(["service": "nginx", "since": "today"]) == "journalctl -u nginx -n 200 --since 'today' | grep nginx")
        #expect(Snippet(title: "x", command: "uptime").placeholders.isEmpty)
        // Shell braces that aren't placeholders stay.
        #expect(Snippet(title: "x", command: "echo ${HOME} {a,b}").filled([:]) == "echo ${HOME} {a,b}")
    }

    @Test func titlesAndOrder() {
        #expect(Snippet.suggestedTitle(for: "sudo systemctl restart nginx && echo ok") == "systemctl restart nginx &&")
        #expect(Snippet.suggestedTitle(for: "df -h\nfree -m") == "df -h")
        let server = UUID()
        var a = Snippet(title: "a", command: "a"); a.uses = 1
        var b = Snippet(title: "b", command: "b"); b.uses = 5
        let mine = Snippet(title: "m", command: "m", serverID: server)
        let other = Snippet(title: "o", command: "o", serverID: UUID())
        #expect(Snippet.forServer(server, in: [a, other, b, mine]).map(\.title) == ["m", "b", "a"])
        #expect(Snippet.forServer(nil, in: [a, other, b, mine]).map(\.title) == ["b", "a"])
    }

    @Test func roundTrip() throws {
        let s = Snippet(title: "Disk", command: "df -h {{path:/}}", serverID: UUID())
        #expect(try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(s)) == s)
    }
}
