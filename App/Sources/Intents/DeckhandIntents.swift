import AppIntents
import DeckhandCore
import DeckhandSSH
import Foundation
import SwiftData

// Siri and Shortcuts: server status and commands answer right away, tasks open in the app.

struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
    static let defaultQuery = ServerQuery()
    let id: UUID
    let name: String
    let address: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(address)") }
}

struct ServerQuery: EntityQuery, EnumerableEntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [ServerEntity] {
        try allEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [ServerEntity] { try allEntities() }
    @MainActor func allEntities() throws -> [ServerEntity] {
        try DeckhandApp.container.mainContext.fetch(FetchDescriptor<Server>(sortBy: [SortDescriptor(\.createdAt)]))
            .map { ServerEntity(id: $0.id, name: $0.displayName, address: $0.address) }
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case serverGone
    case failed(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .serverGone: "That server isn't in Deckhand anymore."
        case .failed(let m): "\(m)"
        }
    }
}

@MainActor
private func lookUpServer(_ entity: ServerEntity) throws -> Server {
    let id = entity.id
    guard let s = try DeckhandApp.container.mainContext.fetch(FetchDescriptor<Server>(predicate: #Predicate { $0.id == id })).first else {
        throw IntentError.serverGone
    }
    return s
}

struct ServerStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check a server"
    static let description = IntentDescription("CPU, memory, disk and uptime of one of your servers.")

    @Parameter(title: "Server") var server: ServerEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let s = try lookUpServer(server)
        do {
            let conn = try await Connections.shared.connection(for: s)
            guard let stats = ServerStats.parse(try await conn.run(ServerStats.probeCommand, timeout: .seconds(20)).stdout) else {
                throw IntentError.failed(String(localized: "Couldn't read the server."))
            }
            WidgetSnapshots.record(s, stats)
            let fullest = stats.disks.max { $0.usedFraction < $1.usedFraction }
            let text = String(localized: """
                \(s.displayName): CPU \(Int((stats.cpu * 100).rounded())) %, memory \(Int((stats.memUsedFraction * 100).rounded())) %, \
                disk \(Int(((fullest?.usedFraction ?? 0) * 100).rounded())) %, up \(ByteFormat.duration(stats.uptime)).
                """)
            return .result(value: text, dialog: "\(text)")
        } catch let e as IntentError {
            throw e
        } catch {
            throw IntentError.failed(error.localizedDescription)
        }
    }
}

struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a command on a server"
    static let description = IntentDescription("Runs one shell command and gives back its output.")

    @Parameter(title: "Server") var server: ServerEntity
    @Parameter(title: "Command") var command: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        if let danger = DangerCheck.assess(command: command) {
            try await requestConfirmation(dialog: "\(danger) Run it anyway?")
        }
        let s = try lookUpServer(server)
        do {
            let conn = try await Connections.shared.connection(for: s)
            let r = try await conn.run(command, timeout: .seconds(25))
            let out = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = out.isEmpty ? String(localized: "Done, no output.") : String(out.suffix(1500))
            return .result(value: out, dialog: r.exitCode == 0 ? "\(shown)" : "\(String(localized: "Exit code \(Int(r.exitCode))")): \(shown)")
        } catch {
            throw IntentError.failed(error.localizedDescription)
        }
    }
}

enum TaskEngine: String, AppEnum {
    case claudeCode, codex, ownKey
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static let caseDisplayRepresentations: [TaskEngine: DisplayRepresentation] = [
        .claudeCode: "Claude Code", .codex: "Codex", .ownKey: "Your own key",
    ]
}

struct StartTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Start an agent task"
    static let description = IntentDescription("Opens Deckhand and gives the agent a task on one of your servers.")
    static let openAppWhenRun = true

    @Parameter(title: "Server") var server: ServerEntity
    @Parameter(title: "Task") var prompt: String
    @Parameter(title: "Agent", default: .codex) var engine: TaskEngine

    @MainActor
    func perform() async throws -> some IntentResult {
        let s = try lookUpServer(server)
        let context = DeckhandApp.container.mainContext
        let thread = ChatThread(server: s, workingDirectory: s.recentDirectories.first ?? s.workingDirectory,
                                engine: Engine(rawValue: engine.rawValue) ?? .codex)
        context.insert(thread)
        try? context.save()
        PendingPrompt.set(prompt, for: thread.id)
        AppRouter.shared.pendingThread = thread.id
        return .result()
    }
}

struct DeckhandShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ServerStatusIntent(), phrases: [
            "Check my server with \(.applicationName)", "How is \(\.$server) doing in \(.applicationName)",
        ], shortTitle: "Check a server", systemImageName: "server.rack")
        AppShortcut(intent: StartTaskIntent(), phrases: [
            "Start a task in \(.applicationName)", "Give \(.applicationName) a task",
        ], shortTitle: "Start a task", systemImageName: "sparkles")
        AppShortcut(intent: RunCommandIntent(), phrases: [
            "Run a command with \(.applicationName)",
        ], shortTitle: "Run a command", systemImageName: "terminal")
    }
}
