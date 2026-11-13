import Foundation
import Testing
@testable import DeckhandCore

struct CommandPaletteTests {
    @Test func ranking() {
        let names = ["web-1", "web-2 (staging)", "database", "Webhook relay"]
        let ranked = names.compactMap { n in CommandPalette.score("web", n).map { (n, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
        #expect(ranked.prefix(2).allSatisfy { $0.hasPrefix("web-") } && ranked.contains("Webhook relay"))
        #expect(CommandPalette.score("dbs", "database")! > 0)            // letters in order
        #expect(CommandPalette.score("xyz", "database") == nil)
        #expect(CommandPalette.score("staging", "web-2 (staging)")! > CommandPalette.score("stg", "web-2 (staging)")!)
    }

    @Test func actions() {
        #expect(CommandPalette.action("restart nginx on web-1") == .init(verb: .restart, service: "nginx", server: "web-1"))
        #expect(CommandPalette.action("Logs of the shop service on prod box") == .init(verb: .logs, service: "shop", server: "prod box"))
        #expect(CommandPalette.action("status docker") == .init(verb: .status, service: "docker", server: nil))
        #expect(CommandPalette.action("restart nginx; rm -rf /") == nil)
        #expect(CommandPalette.action("restart") == nil && CommandPalette.action("make coffee") == nil)
        #expect(CommandPalette.command(.init(verb: .restart, service: "nginx", server: nil)) == "systemctl restart 'nginx' && systemctl is-active 'nginx'")
        #expect(CommandPalette.Verb.restart.needsRoot && !CommandPalette.Verb.status.needsRoot && CommandPalette.Verb.stop.disruptive)
    }
}
