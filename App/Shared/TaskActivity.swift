import ActivityKit
import Foundation

/// A task shown on the Lock Screen and in the Dynamic Island while it runs.
struct TaskActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case running, approval, waiting, done, failed
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// What happens right now, e.g. `npm test` or "Writing the answer".
        var step: String
        /// Set while a usage limit pauses the task.
        var waitingUntil: Date?
        var endedAt: Date?
    }

    var title: String
    var engine: String
    var server: String
    var started: Date
    var threadID: String
}
