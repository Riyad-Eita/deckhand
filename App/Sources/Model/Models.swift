import DeckhandCore
import Foundation
import SwiftData

enum AuthKind: String, Codable, CaseIterable, Identifiable {
    case key
    case password
    var id: String { rawValue }
}

@Model
final class Server {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authKindRaw: String = AuthKind.key.rawValue
    /// OpenSSH host key line, pinned after the first trusted connect.
    var pinnedHostKey: String?
    var workingDirectory: String = "~"
    var createdAt: Date = Date()
    var lastConnectedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \ChatThread.server)
    var threads: [ChatThread]? = []

    init(name: String, host: String, port: Int = 22, username: String, authKind: AuthKind) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authKindRaw = authKind.rawValue
    }

    var authKind: AuthKind {
        get { AuthKind(rawValue: authKindRaw) ?? .key }
        set { authKindRaw = newValue.rawValue }
    }

    var displayName: String { name.isEmpty ? host : name }
    var address: String { port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)" }

    /// Keychain account for this server's password or private key.
    var secretAccount: String { "server.\(id.uuidString)" }
}

/// Who does the work in a thread: the in-app agent with the user's key, or a CLI on the server.
enum Engine: String, Codable, CaseIterable, Identifiable {
    case ownKey
    case codex
    case claudeCode
    var id: String { rawValue }

    var serverCLI: ServerCLI? {
        switch self {
        case .ownKey: nil
        case .codex: .codex
        case .claudeCode: .claudeCode
        }
    }

    var title: String {
        switch self {
        case .ownKey: "Your model key"
        case .codex: "Codex on the server"
        case .claudeCode: "Claude Code on the server"
        }
    }

    var symbol: String {
        switch self {
        case .ownKey: "key.horizontal"
        case .codex, .claudeCode: "server.rack"
        }
    }
}

@Model
final class ChatThread {
    var id: UUID = UUID()
    var title: String = "New task"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var workingDirectory: String = "~"
    var messagesData: Data = Data()
    var engineRaw: String = Engine.ownKey.rawValue
    /// Session id of the server CLI conversation, used to resume it.
    var cliSessionID: String?
    var server: Server?

    init(server: Server, workingDirectory: String, engine: Engine = .ownKey) {
        self.server = server
        self.workingDirectory = workingDirectory
        self.engineRaw = engine.rawValue
    }

    var engine: Engine { Engine(rawValue: engineRaw) ?? .ownKey }

    var messages: [Message] {
        get { (try? JSONDecoder().decode([Message].self, from: messagesData)) ?? [] }
        set {
            messagesData = (try? JSONEncoder().encode(newValue)) ?? Data()
            updatedAt = Date()
        }
    }
}
