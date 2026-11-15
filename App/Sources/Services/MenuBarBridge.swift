#if targetEnvironment(macCatalyst)
import Foundation
import UIKit

/// Running tasks and approvals in the Mac menu bar, through the AppKit bundle DeckhandMenuBar (PlugIns).
@MainActor
final class MenuBarBridge {
    static let shared = MenuBarBridge()
    private var bar: NSObject?
    private var tasks: [UUID: [String: String]] = [:]
    /// The answer for a task that waits for an approval (set by the chat while it waits).
    private var approvals: [UUID: (Bool) -> Void] = [:]

    private init() {
        guard let url = Bundle.main.builtInPlugInsURL?.appending(path: "DeckhandMenuBar.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = bundle.principalClass as? NSObject.Type else { return }
        let bar = type.init()
        let handler: @convention(block) (NSString, NSString) -> Void = { action, id in
            Task { @MainActor in MenuBarBridge.shared.handle(action as String, UUID(uuidString: id as String)) }
        }
        bar.setValue(handler, forKey: "onAction")
        bar.setValue(["waiting": String(localized: "Waiting for you"), "allow": String(localized: "Allow"),
                      "deny": String(localized: "Deny"), "running": String(localized: "Running"),
                      "none": String(localized: "No tasks running"), "open": String(localized: "Open Deckhand")], forKey: "labels")
        self.bar = bar
        #if DEBUG
        // DECKHAND_SEED_MENUBAR=1: a task waiting for approval and one running (screenshots).
        if ProcessInfo.processInfo.environment["DECKHAND_SEED_MENUBAR"] == "1" {
            tasks[UUID()] = ["id": UUID().uuidString, "title": "Fix the 502 on the shop", "server": "web-1", "phase": "approval", "step": "sudo systemctl restart nginx"]
            tasks[UUID()] = ["id": UUID().uuidString, "title": "Free up disk space", "server": "db-1", "phase": "running", "step": "docker image prune"]
        }
        #endif
        push()
        #if DEBUG
        if ProcessInfo.processInfo.environment["DECKHAND_SEED_MENUBAR"] == "open" || ProcessInfo.processInfo.environment["DECKHAND_SEED_MENUBAR_OPEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak bar] in bar?.perform(NSSelectorFromString("openMenu")) }
        }
        #endif
    }

    func start() { _ = bar }

    func set(_ id: UUID, title: String, server: String, phase: String, step: String) {
        tasks[id] = ["id": id.uuidString, "title": title, "server": server, "phase": phase, "step": step]
        push()
    }

    func remove(_ id: UUID) {
        tasks[id] = nil; approvals[id] = nil
        push()
    }

    func waitForApproval(_ id: UUID, answer: @escaping (Bool) -> Void) { approvals[id] = answer }
    func approvalDone(_ id: UUID) { approvals[id] = nil }

    private func push() {
        let list = tasks.values.sorted { ($0["phase"] == "approval" ? 0 : 1, $0["title"] ?? "") < ($1["phase"] == "approval" ? 0 : 1, $1["title"] ?? "") }
        bar?.perform(NSSelectorFromString("update:"), with: list.map { $0 as NSDictionary })
    }

    private func handle(_ action: String, _ id: UUID?) {
        switch action {
        case "allow", "deny":
            guard let id, let answer = approvals.removeValue(forKey: id) else { return }
            answer(action == "allow")
        case "open":
            if let id { AppRouter.shared.pendingThread = id }
        default: break
        }
    }
}
#endif
