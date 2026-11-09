import Foundation

// MARK: - Line channels (a process's stdin/stdout)

/// A running process we exchange newline-delimited text with (stdio MCP servers).
public protocol LineChannel: Sendable {
    var lines: AsyncThrowingStream<String, Error> { get }
    func send(_ line: String) async throws
    func close()
}

/// Splits a byte stream into lines. Thread-safe.
public final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    public init() {}

    /// Appends bytes and returns the complete, non-empty lines.
    public func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                if !line.isEmpty { lines.append(line) }
            }
            return lines
        }
    }
}

#if os(macOS)
/// A local process as a line channel. Used in tests and the Mac build.
public final class LocalProcessChannel: LineChannel, @unchecked Sendable {
    public let lines: AsyncThrowingStream<String, Error>
    private let process = Process()
    private let stdin = Pipe()

    public init(command: String) throws {
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        lines = stream
        let buffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.append(data) { continuation.yield(line) }
        }
        try process.run()
    }

    public func send(_ line: String) async throws {
        try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    public func close() {
        if process.isRunning { process.terminate() }
    }
}
#endif

// MARK: - MCP

public struct MCPTool: Sendable, Hashable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
}

public struct MCPError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Moves JSON-RPC messages to an MCP server and back.
public protocol MCPTransport: Sendable {
    func request(_ method: String, params: JSONValue?) async throws -> JSONValue
    func notify(_ method: String, params: JSONValue?) async throws
    func close() async
}

/// stdio transport: one JSON-RPC message per line.
public actor StdioMCPTransport: MCPTransport {
    private let channel: any LineChannel
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var reader: Task<Void, Never>?
    private var closedError: Error?

    public init(channel: any LineChannel) {
        self.channel = channel
    }

    private func startReader() {
        guard reader == nil else { return }
        let lines = channel.lines
        reader = Task { [weak self] in
            do {
                for try await line in lines {
                    guard let message = try? JSONValue.parse(line) else { continue }
                    await self?.receive(message)
                }
                await self?.fail(MCPError("The MCP server closed the connection."))
            } catch {
                await self?.fail(error)
            }
        }
    }

    private func receive(_ message: JSONValue) {
        if let id = message["id"]?.intValue, message["method"] == nil, let waiter = waiting.removeValue(forKey: id) {
            if let error = message["error"] {
                waiter.resume(throwing: MCPError(error["message"]?.stringValue ?? "MCP error"))
            } else {
                waiter.resume(returning: message["result"] ?? .null)
            }
        } else if let method = message["method"]?.stringValue, let id = message["id"] {
            // Server-to-client request (ping, roots, sampling…): answer ping, decline the rest.
            let reply: JSONValue = method == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": [:]]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported"]]
            let channel = self.channel
            Task { try? await channel.send(reply.jsonString()) }
        }
    }

    private func fail(_ error: Error) {
        closedError = error
        for (_, waiter) in waiting { waiter.resume(throwing: error) }
        waiting = [:]
    }

    public func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        if let closedError { throw closedError }
        startReader()
        let id = nextID
        nextID += 1
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { message["params"] = params }
        let line = JSONValue.object(message).jsonString()
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            let channel = self.channel
            Task {
                do { try await channel.send(line) } catch { self.resumeFailed(id: id, error: error) }
            }
        }
    }

    private func resumeFailed(id: Int, error: Error) {
        waiting.removeValue(forKey: id)?.resume(throwing: error)
    }

    public func notify(_ method: String, params: JSONValue?) async throws {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        try await channel.send(JSONValue.object(message).jsonString())
    }

    public func close() async {
        reader?.cancel()
        channel.close()
        fail(MCPError("Closed."))
    }
}

/// Streamable HTTP transport (MCP 2025-03-26 and later): POST each message, reply is JSON or an SSE stream.
public actor HTTPMCPTransport: MCPTransport {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private var sessionID: String?
    private var protocolVersion: String?
    private var nextID = 1

    public init(url: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    private func makeRequest(_ body: JSONValue) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let sessionID { r.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { r.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        r.httpBody = try body.jsonData()
        return r
    }

    public func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { message["params"] = params }
        let (data, response) = try await session.data(for: try makeRequest(.object(message)))
        guard let http = response as? HTTPURLResponse else { throw MCPError("No HTTP response") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MCPError("The MCP server refused the credentials (\(http.statusCode)).")
            }
            throw MCPError("MCP server error \(http.statusCode): \(String(decoding: data.prefix(500), as: UTF8.self))")
        }
        let reply = try Self.findReply(id: id, data: data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
        if let error = reply["error"] { throw MCPError(error["message"]?.stringValue ?? "MCP error") }
        let result = reply["result"] ?? .null
        if method == "initialize", let v = result["protocolVersion"]?.stringValue { protocolVersion = v }
        return result
    }

    static func findReply(id: Int, data: Data, contentType: String) throws -> JSONValue {
        let text = String(decoding: data, as: UTF8.self)
        if contentType.contains("text/event-stream") {
            var parser = SSEParser()
            var events: [SSEParser.Event] = []
            for line in text.components(separatedBy: "\n") { if let e = parser.feed(line: line) { events.append(e) } }
            if let e = parser.flush() { events.append(e) }
            for event in events {
                if let json = try? JSONValue.parse(event.data), json["id"]?.intValue == id { return json }
            }
            throw MCPError("The MCP server's stream had no reply.")
        }
        let json = try JSONValue.parse(text)
        if let batch = json.arrayValue { return batch.first { $0["id"]?.intValue == id } ?? .null }
        return json
    }

    public func notify(_ method: String, params: JSONValue?) async throws {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        _ = try await session.data(for: try makeRequest(.object(message)))
    }

    public func close() async {
        guard let sessionID else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "DELETE"
        r.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await session.data(for: r)
    }
}

/// A connected MCP server.
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"

    public let name: String
    private let transport: any MCPTransport
    public private(set) var serverName: String?
    public private(set) var instructions: String?
    private var initialized = false

    public init(name: String, transport: any MCPTransport) {
        self.name = name
        self.transport = transport
    }

    public func connect() async throws {
        guard !initialized else { return }
        let result = try await transport.request("initialize", params: [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": [:],
            "clientInfo": ["name": "Deckhand", "version": "1.0"],
        ])
        serverName = result["serverInfo"]?["name"]?.stringValue
        instructions = result["instructions"]?.stringValue
        try await transport.notify("notifications/initialized", params: nil)
        initialized = true
    }

    public func tools() async throws -> [MCPTool] {
        try await connect()
        var all: [MCPTool] = []
        var cursor: JSONValue?
        repeat {
            let result = try await transport.request("tools/list", params: cursor.map { ["cursor": $0] })
            for t in result["tools"]?.arrayValue ?? [] {
                guard let name = t["name"]?.stringValue else { continue }
                all.append(MCPTool(
                    name: name,
                    description: t["description"]?.stringValue ?? "",
                    inputSchema: t["inputSchema"] ?? ["type": "object", "properties": [:]]))
            }
            cursor = result["nextCursor"]
            if cursor == .null { cursor = nil }
        } while cursor != nil
        return all
    }

    /// Calls a tool; returns its text content and whether the server flagged an error.
    public func call(_ tool: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        try await connect()
        let result = try await transport.request("tools/call", params: ["name": .string(tool), "arguments": arguments])
        var parts: [String] = []
        for item in result["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "text": parts.append(item["text"]?.stringValue ?? "")
            case "resource": parts.append(item["resource"]?["text"]?.stringValue ?? item["resource"]?["uri"]?.stringValue ?? "")
            case "resource_link": parts.append(item["uri"]?.stringValue ?? "")
            case "image", "audio": parts.append("[\(item["type"]?.stringValue ?? "media") \(item["mimeType"]?.stringValue ?? "")]")
            default: parts.append(item.jsonString())
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"] { parts.append(structured.jsonString()) }
        return (parts.joined(separator: "\n"), result["isError"]?.boolValue ?? false)
    }

    public func close() async { await transport.close() }
}

/// Exposes one MCP tool to the agent loop.
public struct MCPAgentTool: AgentTool {
    public let client: MCPClient
    public let tool: MCPTool
    public let exposedName: String
    public var isReadOnly: Bool { false }

    public init(client: MCPClient, serverName: String, tool: MCPTool) {
        self.client = client
        self.tool = tool
        self.exposedName = Self.toolName(server: serverName, tool: tool.name)
    }

    public var spec: ToolSpec {
        ToolSpec(name: exposedName, description: tool.description, inputSchema: tool.inputSchema)
    }

    public func execute(_ input: JSONValue, shell: any RemoteShell) async throws -> String {
        let (text, isError) = try await client.call(tool.name, arguments: input)
        if isError { throw ToolError.failed(text.isEmpty ? "The tool reported an error." : text) }
        return clip(text)
    }

    /// Tool names must match ^[a-zA-Z0-9_-]{1,64}$ for the model APIs.
    public static func toolName(server: String, tool: String) -> String {
        let raw = "\(server)__\(tool)"
        let cleaned = String(raw.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.filter(\.isASCII))
        return String(cleaned.prefix(64))
    }
}
