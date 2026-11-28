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

/// Task templates: snippets whose text is an agent prompt, kept apart from terminal commands.
@Suite struct TaskTemplateTests {
    @Test func templatesAreKeptApartFromCommands() throws {
        let server = UUID()
        let all = [
            Snippet(title: "Disk", command: "df -h", serverID: server),
            Snippet(title: "Restart", command: "Restart {{service:nginx}} and check its log", serverID: server, kind: .task),
            Snippet(title: "Updates", command: "Update the packages", kind: .task),
        ]
        #expect(Snippet.forServer(server, in: all).map(\.title) == ["Disk"])
        #expect(Snippet.forServer(server, in: all, kind: .task).map(\.title) == ["Restart", "Updates"])
        #expect(Snippet.forServer(UUID(), in: all, kind: .task).map(\.title) == ["Updates"])
        let t = all[1]
        #expect(t.placeholders.map(\.name) == ["service"])
        #expect(t.filled([:]) == "Restart nginx and check its log")
        #expect(t.filled(["service": "redis"]) == "Restart redis and check its log")
    }

    @Test func savedBeforeTemplatesExistedMeansCommand() throws {
        let old = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Disk","command":"df -h","uses":2}]"#
        let list = try JSONDecoder().decode([Snippet].self, from: Data(old.utf8))
        #expect(list[0].kind == .command && list[0].uses == 2)
        let task = Snippet(title: "T", command: "Do it", kind: .task)
        #expect(try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(task)).kind == .task)
        #expect(Snippet.suggestedTaskTitle(for: "Check why nginx returns 502 errors on the staging host since this morning\nmore") == "Check why nginx returns 502 errors on the stagin…")
    }
}
