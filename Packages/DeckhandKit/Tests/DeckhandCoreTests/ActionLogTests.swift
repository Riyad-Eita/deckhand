import Foundation
import Testing
@testable import DeckhandCore

struct ActionLogTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    var messages: [Message] {
        let run = ToolCall(id: "a", name: "run_command", input: ["command": "systemctl restart shop"])
        let edit = ClaudeCodeEventDecoder.normalize(id: "b", name: "Edit", input: ["file_path": "/etc/nginx/sites-available/shop", "old_string": "8080", "new_string": "8081"])
        let mcp = ToolCall(id: "c", name: "github__create_issue", input: ["title": "x"])
        return [
            Message(role: .user, blocks: [.text("Move the shop")], date: t0),
            Message(role: .assistant, blocks: [.toolUse(edit), .toolUse(run)], date: t0.addingTimeInterval(5)),
            Message(role: .user, blocks: [.toolResult(ToolResult(toolUseID: "b", content: "ok")),
                                          .toolResult(ToolResult(toolUseID: "a", content: "Job failed\nsee journalctl", isError: true))], date: t0.addingTimeInterval(9)),
            Message(role: .assistant, blocks: [.toolUse(mcp)], date: t0.addingTimeInterval(12)),
        ]
    }

    @Test func entriesForEveryEngine() {
        let e = ActionLog.entries(messages)
        #expect(e.map(\.kind) == [.edit, .command, .other])
        #expect(e[0].detail == "/etc/nginx/sites-available/shop" && e[0].failed == false)
        #expect(e[1].detail == "systemctl restart shop" && e[1].failed == true && e[1].output.hasPrefix("Job failed"))
        #expect(e[2].detail == "github · create_issue" && e[2].failed == nil && e[2].date == t0.addingTimeInterval(12))
        let t = ActionLog.totals(e)
        #expect(t.commands == 1 && t.changedFiles == 1 && t.failed == 1 && t.first == t0.addingTimeInterval(5))
    }

    @Test func markdownExport() {
        let md = ActionLog.markdown(title: "Move the shop", server: "web-1", folder: "~/shop", engine: "Claude Code",
                                    entries: ActionLog.entries(messages), now: t0)
        #expect(md.hasPrefix("# Move the shop\n\n- Server: web-1"))
        #expect(md.contains("- Actions: 3 (1 commands, 1 files changed, 1 failed)"))
        #expect(md.contains("### 2027-01-15T08:00:05Z · command ✗\n\n```\nsystemctl restart shop\n```"))
    }

    @Test func oldMessagesWithoutTimesStillDecode() throws {
        let old = #"{"id":"8C5A2E6E-1A2B-4C3D-9E8F-001122334455","role":"user","blocks":[{"text":{"_0":"hi"}}]}"#
        let m = try JSONDecoder().decode(Message.self, from: Data(old.utf8))
        #expect(m.date == nil && m.text == "hi")
    }
}
