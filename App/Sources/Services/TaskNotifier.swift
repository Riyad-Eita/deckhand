import BackgroundTasks
import DeckhandCore
import Foundation
import SwiftData
import UIKit
import UserNotifications

/// Tells you when a task is done or waits for your approval: right away while the app runs, and through
/// occasional background checks of the server once it's closed. With an ntfy topic the server pushes itself.
@MainActor
final class TaskNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TaskNotifier()
    static let refreshID = "de.fs223.deckhand.runs"
    private let center = UNUserNotificationCenter.current()
    private var notified: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "notify.sent") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: "notify.sent") }
    }

    func start() {
        center.delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            Task { @MainActor in
                let ok = await TaskNotifier.shared.checkServers()
                task.setTaskCompleted(success: ok)
            }
        }
    }

    /// Asked once, the first time a task starts.
    func requestPermission() {
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    func taskFinished(_ thread: ChatThread, ok: Bool) {
        guard let run = thread.cliRunID, !notified.contains(run) else { return }
        notified.insert(run)
        guard UIApplication.shared.applicationState != .active || AppRouter.shared.visibleThread != thread.id else { return }
        post(id: run, title: ok ? String(localized: "Task done") : String(localized: "Task stopped"), body: thread.title, thread: thread.id)
    }

    func approvalNeeded(_ thread: ChatThread, command: String) {
        guard UIApplication.shared.applicationState != .active || AppRouter.shared.visibleThread != thread.id else { return }
        post(id: "approval-\(thread.id)", title: String(localized: "Approval needed"), body: "\(thread.title): \(command)", thread: thread.id)
    }

    private func post(id: String, title: String, body: String, thread: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["thread": thread.uuidString]
        content.threadIdentifier = thread.uuidString
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: Background

    /// Called when the app goes to the background with tasks still running on servers.
    func scheduleCheck(hasActiveRuns: Bool) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
        guard hasActiveRuns else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Looks at every running task on its server; notifies about the ones that ended.
    func checkServers() async -> Bool {
        let context = ModelContext(DeckhandApp.container)
        let threads = ((try? context.fetch(FetchDescriptor<ChatThread>())) ?? []).filter { $0.cliRunActive && $0.cliRunID != nil }
        var stillRunning = false
        for thread in threads {
            guard let server = thread.server, let id = thread.cliRunID,
                  let conn = try? await Connections.shared.connection(for: server),
                  let r = try? await conn.run(DetachedRun(id: id).statusCommand + "; cat \(DetachedRun(id: id).base).exit 2>/dev/null", timeout: .seconds(15))
            else { stillRunning = true; continue }
            let lines = r.stdout.split(separator: "\n")
            if lines.first == "ended" {
                if lines.last != "143" { taskFinished(thread, ok: lines.last == "0") }
            } else {
                stillRunning = true
            }
        }
        scheduleCheck(hasActiveRuns: stillRunning)
        return true
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["thread"] as? String, let id = UUID(uuidString: s) else { return }
        await MainActor.run { AppRouter.shared.pendingThread = id }
    }

    /// Sends a test message to the ntfy topic from the phone.
    static func testNtfy(_ topicURL: String) async -> Bool {
        guard let url = URL(string: topicURL) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Deckhand", forHTTPHeaderField: "Title")
        request.httpBody = Data(String(localized: "Notifications from your server work.").utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func newTopicURL() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "https://ntfy.sh/deckhand-" + String((0..<20).map { _ in chars.randomElement()! })
    }
}
