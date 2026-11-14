import Foundation
import Testing
@testable import DeckhandCore

@Suite struct TaskExportTests {
    let messages: [Message] = [
        .user("Why does nginx return 502?"),
        Message(role: .assistant, blocks: [.text("Let me check the upstream."),
                                           .toolUse(ToolCall(id: "1", name: "run_command", input: ["command": "systemctl status php8.3-fpm"]))]),
        Message(role: .user, blocks: [.toolResult(ToolResult(toolUseID: "1", content: "Active: failed (Result: exit-code)\nDB_PASSWORD=hunter2secret"))]),
        Message(role: .assistant, blocks: [.text("PHP-FPM crashed. Restart it with `systemctl restart php8.3-fpm`.")]),
    ]

    @Test func search() {
        #expect(TaskExport.match("nginx", title: "Fix 502", messages: messages).matches)
        #expect(TaskExport.match("NGINX 502", title: "Fix 502", messages: messages).snippet?.contains("nginx") == true)
        #expect(TaskExport.match("fpm failed", title: "x", messages: messages).matches)
        // A title hit needs no snippet.
        let titleHit = TaskExport.match("fix", title: "Fix 502", messages: messages)
        #expect(titleHit.matches && titleHit.snippet == nil)
        #expect(!TaskExport.match("postgres", title: "Fix 502", messages: messages).matches)
        #expect(TaskExport.match("", title: "anything", messages: []).matches)
        #expect(TaskExport.match("cafe", title: "Café setup", messages: []).matches)
    }

    @Test func markdownExport() {
        let md = TaskExport.markdown(title: "Fix 502", server: "web-1", folder: "~/app", date: Date(timeIntervalSince1970: 1_763_000_000), messages: messages)
        #expect(md.hasPrefix("# Fix 502\n\nServer: web-1 · Folder: `~/app` · Date: 2025-"))
        #expect(md.contains("## You\n\nWhy does nginx return 502?"))
        #expect(md.contains("```sh\n$ systemctl status php8.3-fpm\n```"))
        #expect(md.contains("Active: failed"))
        #expect(!md.contains("hunter2secret"))
        #expect(TaskExport.fileName(for: "Fix 502 / nginx: upstream?") == "Fix 502 - nginx- upstream-.md")
        #expect(TaskExport.fileName(for: "  ") == "Task.md")
    }
}
