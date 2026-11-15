import AppKit

/// The menu bar item of the Mac app. Mac Catalyst can't use AppKit, so the app loads this bundle at runtime and
/// talks to it through Objective-C: `update(_:)` with the current tasks, `onAction` for what the user picked.
/// Entries: `id` (task), `title`, `server`, `phase` ("running" | "approval" | "waiting"), `step`.
@MainActor @objc(DeckhandMenuBar)
public final class DeckhandMenuBar: NSObject {
    private var item: NSStatusItem?
    private var entries: [[String: String]] = []
    /// (action, task id): "open", "allow", "deny", "app".
    @objc public var onAction: ((String, String) -> Void)?
    /// Texts in the app's language (the bundle has no translations of its own).
    @objc public var labels: [String: String] = [:]
    private func L(_ key: String, _ english: String) -> String { labels[key] ?? english }

    @objc public func update(_ entries: [NSDictionary]) {
        self.entries = entries.compactMap { $0 as? [String: String] }
        render()   // the app calls on the main thread
    }

    /// Opens the menu as if clicked (debug screenshots).
    @objc public func openMenu() { item?.button?.performClick(nil) }

    private func render() {
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        guard let button = item?.button else { return }
        let waiting = entries.filter { $0["phase"] == "approval" }
        let running = entries.filter { $0["phase"] != "approval" }
        let symbol = waiting.isEmpty ? (running.isEmpty ? "terminal" : "terminal.fill") : "exclamationmark.bubble.fill"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Deckhand")
        button.image?.isTemplate = true
        button.title = entries.isEmpty ? "" : " \(entries.count)"
        button.imagePosition = .imageLeading
        button.setAccessibilityIdentifier("deckhand.menubar")

        let menu = NSMenu()
        if !waiting.isEmpty {
            menu.addItem(.sectionHeader(title: L("waiting", "Waiting for you")))
            for e in waiting {
                menu.addItem(entry(e))
                menu.addItem(action(L("allow", "Allow"), "allow", e, symbol: "checkmark.circle"))
                menu.addItem(action(L("deny", "Deny"), "deny", e, symbol: "xmark.circle"))
            }
        }
        if !running.isEmpty {
            if !waiting.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: L("running", "Running")))
            for e in running { menu.addItem(entry(e)) }
        }
        if entries.isEmpty {
            let none = NSMenuItem(title: L("none", "No tasks running"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: L("open", "Open Deckhand"), action: #selector(picked(_:)), keyEquivalent: "")
        open.target = self; open.representedObject = ["app", ""]
        menu.addItem(open)
        item?.menu = menu
    }

    private func entry(_ e: [String: String]) -> NSMenuItem {
        let title = [e["server"], e["title"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let m = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
        m.subtitle = e["step"]
        m.target = self; m.representedObject = ["open", e["id"] ?? ""]
        return m
    }

    private func action(_ title: String, _ kind: String, _ e: [String: String], symbol: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
        m.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        m.indentationLevel = 1
        m.target = self; m.representedObject = [kind, e["id"] ?? ""]
        return m
    }

    @objc private func picked(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [String], p.count == 2 else { return }
        if p[0] != "allow" && p[0] != "deny" { NSApp.activate() }
        onAction?(p[0], p[1])
    }
}
