import Foundation

/// Incremental parser for `text/event-stream` bodies. Feed it lines; it returns complete events.
public struct SSEParser: Sendable {
    public struct Event: Sendable, Hashable {
        public var event: String?
        public var data: String
    }

    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feed one line (without the trailing newline). Returns an event when a blank line ends one.
    public mutating func feed(line rawLine: String) -> Event? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }

    /// Call when the stream ends to emit a trailing event without a blank line.
    public mutating func flush() -> Event? {
        defer { eventName = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        return Event(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}

extension URLSession {
    /// Streams server-sent events from a request. Throws `LLMError.http` for non-2xx responses.
    func serverSentEvents(for request: URLRequest) -> AsyncThrowingStream<SSEParser.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await self.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line + "\n"
                            if body.count > 8_000 { break }
                        }
                        throw LLMError.http(status: http.statusCode, body: body)
                    }
                    var parser = SSEParser()
                    // `lines` drops empty lines, so read raw bytes and split ourselves.
                    var buffer = Data()
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            let line = String(decoding: buffer, as: UTF8.self)
                            buffer.removeAll(keepingCapacity: true)
                            if let event = parser.feed(line: line) { continuation.yield(event) }
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty, let event = parser.feed(line: String(decoding: buffer, as: UTF8.self)) {
                        continuation.yield(event)
                    }
                    if let event = parser.flush() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
