import ActivityKit
import DeckhandCore
import Foundation

/// The Lock Screen / Dynamic Island card for running tasks. Updated from the chat while the app runs
/// (at most every few seconds); the elapsed time counts by itself.
@MainActor
final class LiveTasks {
    static let shared = LiveTasks()
    private var activities: [UUID: Activity<TaskActivityAttributes>] = [:]
    private var lastUpdate: [UUID: Date] = [:]

    func start(_ thread: ChatThread, server: Server) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activities[thread.id] == nil else { return }
        let attributes = TaskActivityAttributes(
            title: thread.title, engine: thread.engine.shortTitle, server: server.displayName,
            started: Date(), threadID: thread.id.uuidString)
        let state = TaskActivityAttributes.ContentState(phase: .running, step: String(localized: "Starting…"))
        activities[thread.id] = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    func update(_ thread: ChatThread, phase: TaskActivityAttributes.Phase, step: String, waitingUntil: Date? = nil, force: Bool = false) {
        guard let activity = activities[thread.id] else { return }
        if !force, let last = lastUpdate[thread.id], Date().timeIntervalSince(last) < 3 { return }
        lastUpdate[thread.id] = Date()
        let state = TaskActivityAttributes.ContentState(phase: phase, step: step, waitingUntil: waitingUntil)
        let id = activity.id
        Task { await Self.activity(id)?.update(.init(state: state, staleDate: nil)) }
    }

    func end(_ thread: ChatThread, ok: Bool, stopped: Bool = false) {
        guard let activity = activities.removeValue(forKey: thread.id) else { return }
        lastUpdate[thread.id] = nil
        let step = stopped ? String(localized: "Stopped") : ok ? String(localized: "Done") : String(localized: "Didn't finish")
        let state = TaskActivityAttributes.ContentState(phase: ok ? .done : .failed, step: step, endedAt: Date())
        let id = activity.id
        Task { await Self.activity(id)?.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(15 * 60))) }
    }

    /// Looked up by id inside the task: `Activity` isn't Sendable.
    private nonisolated static func activity(_ id: String) -> Activity<TaskActivityAttributes>? {
        Activity<TaskActivityAttributes>.activities.first { $0.id == id }
    }

    /// A short line for what a tool call does.
    static func step(for call: ToolCall) -> String {
        func s(_ k: String) -> String { call.input[k]?.stringValue ?? "" }
        let file = { (p: String) in (p as NSString).lastPathComponent }
        switch call.name {
        case "run_command": return "$ " + String(s("command").split(separator: "\n").first ?? "").prefix(80)
        case "read_file": return String(localized: "Reading \(file(s("path")))")
        case "write_file", "edit_file": return String(localized: "Editing \(file(s("path")))")
        case "search": return String(localized: "Searching for \(s("pattern"))")
        case "list_directory": return String(localized: "Looking around \(s("path"))")
        default: return call.name.replacingOccurrences(of: "_", with: " ")
        }
    }
}
