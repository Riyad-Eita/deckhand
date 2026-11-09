import DeckhandCore
import DeckhandSSH
import Foundation

/// Opens the user's MCP connections for one agent run and turns them into agent tools.
enum MCPConnector {
    struct Opened {
        var tools: [any AgentTool] = []
        var clients: [MCPClient] = []
        /// Connections that could not be opened, with the reason.
        var failures: [(name: String, error: String)] = []

        func close() async {
            for c in clients { await c.close() }
        }
    }

    static func client(for spec: MCPConnection, token: String?, server: SSHConnection?) async throws -> MCPClient {
        switch spec.transport {
        case .http(let url):
            guard let u = URL(string: url) else { throw MCPError("Invalid URL") }
            var headers: [String: String] = [:]
            if let token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
            return MCPClient(name: spec.slug, transport: HTTPMCPTransport(url: u, headers: headers))
        case .stdio(let command):
            guard let server else { throw MCPError("Needs a server to run on.") }
            return MCPClient(name: spec.slug, transport: StdioMCPTransport(channel: try await server.openChannel(command)))
        }
    }

    /// Opens all enabled connections in parallel; each gets 20 s.
    static func open(_ records: [(MCPConnection, String?)], server: SSHConnection?) async -> Opened {
        await withTaskGroup(of: (String, Result<(MCPClient, [MCPTool]), Error>).self) { group in
            for (spec, token) in records where spec.enabled {
                group.addTask {
                    do {
                        let client = try await client(for: spec, token: token, server: server)
                        let tools = try await withTimeout(seconds: 20) { try await client.tools() }
                        return (spec.slug, .success((client, tools)))
                    } catch {
                        return (spec.slug, .failure(error))
                    }
                }
            }
            var opened = Opened()
            for await (name, result) in group {
                switch result {
                case .success(let (client, tools)):
                    opened.clients.append(client)
                    opened.tools += tools.map { MCPAgentTool(client: client, serverName: name, tool: $0) }
                case .failure(let error):
                    opened.failures.append((name, error.localizedDescription))
                }
            }
            return opened
        }
    }

    static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPError("Timed out after \(Int(seconds)) s.")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
