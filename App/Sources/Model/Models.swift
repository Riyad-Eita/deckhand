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
    /// Folders recently chosen for tasks, newest first.
    var recentDirectories: [String] = []
    /// Optional group ("production", "home lab") for running commands on several servers.
    var group: String = ""
    /// Another server to connect through (jump host / bastion, like `ssh -J`).
    var jumpHostID: UUID?
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
    var address: String {
        #if DEBUG
        if let shown = DebugSeed.displayAddress(for: self) { return shown }
        #endif
        return port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
    }

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
        case .ownKey: String(localized: "Your model key")
        case .codex: String(localized: "Codex on the server")
        case .claudeCode: String(localized: "Claude Code on the server")
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
    /// The detached run on the server for the current CLI turn, and the next output line to read.
    var cliRunID: String?
    var cliRunLine: Int = 1
    var cliRunActive: Bool = false
    /// Model and effort for Claude Code / Codex in this task; nil = the default from Settings.
    var cliModel: String?
    var cliEffort: String?
    /// Long own-key tasks: messages before this index were summarized into `historySummary` and aren't sent again.
    var historyStart: Int = 0
    var historySummary: String?
    /// "Plan first": the next requests run read-only and come back as a plan to run, adjust or drop.
    var planFirst: Bool = false
    /// Plain chats (no server): the provider and model this chat talks to; nil = the default from Settings.
    var chatProviderRaw: String?
    var chatModel: String?
    /// Pinned tasks stay at the top of the server's list.
    var pinned: Bool = false
    var server: Server?

    /// A plain chat with a model, without a server.
    init(chatWith provider: ProviderKind?) {
        self.server = nil
        self.chatProviderRaw = provider?.rawValue
        self.title = String(localized: "New chat")
    }

    var isPlainChat: Bool { server == nil }

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

/// An MCP server connected in the app. Tokens live in the Keychain under `secretAccount`.
@Model
final class ConnectionRecord {
    var id: UUID = UUID()
    var name: String = ""
    /// "http" or "stdio"
    var kind: String = "http"
    var url: String = ""
    var command: String = ""
    var enabled: Bool = true
    var createdAt: Date = Date()

    init(name: String, kind: String, url: String = "", command: String = "") {
        self.name = name
        self.kind = kind
        self.url = url
        self.command = command
    }

    var secretAccount: String { "connection.\(id.uuidString)" }
    var token: String? { Keychain.get(secretAccount) }

    var spec: MCPConnection {
        MCPConnection(
            id: id, name: name,
            transport: kind == "stdio" ? .stdio(command: command) : .http(url: url),
            enabled: enabled)
    }

    var summary: String { kind == "stdio" ? "$ " + command : url }

    @MainActor var brand: Brand? {
        if kind == "stdio" { return nil }
        return url.contains("github") ? .github : .mcp
    }
}
