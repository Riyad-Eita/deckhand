import DeckhandCore
import DeckhandSSH
import Foundation
import Observation

/// The HTTP client's collections: a JSON file in Application Support; secret variable values in the Keychain.
@MainActor
@Observable
final class HTTPStore {
    static let shared = HTTPStore()

    var collections: [HTTPClient.Collection] = [] { didSet { save() } }
    private var loading = false

    private static var file: URL {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "http-collections.json")
    }

    init() {
        loading = true
        if let data = try? Data(contentsOf: Self.file), let list = try? JSONDecoder().decode([HTTPClient.Collection].self, from: data) {
            collections = list
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        // Secret values never go into the file.
        var copy = collections
        for c in copy.indices { for e in copy[c].environments.indices { for v in copy[c].environments[e].variables.indices where copy[c].environments[e].variables[v].secret {
            copy[c].environments[e].variables[v].value = ""
        } } }
        if let data = try? JSONEncoder().encode(copy) { try? data.write(to: Self.file, options: [.atomic, .completeFileProtection]) }
    }

    static func secretAccount(_ v: HTTPClient.Variable) -> String { "http.var.\(v.id.uuidString)" }

    func secret(_ v: HTTPClient.Variable) -> String { Keychain.get(Self.secretAccount(v)) ?? "" }
    func setSecret(_ value: String, for v: HTTPClient.Variable) { Keychain.set(value.isEmpty ? nil : value, for: Self.secretAccount(v)) }

    /// The active environment's variables, secrets read from the Keychain.
    func variables(of c: HTTPClient.Collection) -> [String: String] {
        guard let env = c.environments.first(where: { $0.id == c.activeEnvironment }) ?? c.environments.first else { return [:] }
        var out: [String: String] = [:]
        for v in env.variables where !v.name.isEmpty { out[v.name] = v.secret ? secret(v) : v.value }
        return out
    }

    func index(of id: UUID) -> Int? { collections.firstIndex { $0.id == id } }

    func delete(_ c: HTTPClient.Collection) {
        for e in c.environments { for v in e.variables where v.secret { setSecret("", for: v) } }
        collections.removeAll { $0.id == c.id }
    }

    // MARK: - Sending

    enum SendError: LocalizedError {
        case badURL(String), server(String)
        var errorDescription: String? {
            switch self {
            case .badURL(let u): String(localized: "That isn't a URL: \(u)")
            case .server(let m): m
            }
        }
    }

    /// From this iPhone.
    static func sendFromPhone(_ r: HTTPClient.Resolved, timeout: TimeInterval = 30) async throws -> HTTPClient.Response {
        guard let url = URL(string: r.url), url.scheme == "http" || url.scheme == "https", url.host() != nil else { throw SendError.badURL(r.url) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = r.method.rawValue
        for (k, v) in r.headers { req.addValue(v, forHTTPHeaderField: k) }
        if !r.body.isEmpty, r.method != .GET, r.method != .HEAD { req.httpBody = Data(r.body.utf8) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let start = Date()
        let (data, response) = try await URLSession(configuration: config).data(for: req)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { headers[String(describing: k).lowercased()] = String(describing: v) }
        return HTTPClient.Response(status: http?.statusCode ?? 0, headers: headers,
                                   body: String(data: data, encoding: .utf8) ?? String(localized: "\(data.count) bytes of binary data"),
                                   seconds: Date().timeIntervalSince(start), bytes: data.count)
    }

    /// From a server's network, with curl over SSH.
    static func sendFromServer(_ r: HTTPClient.Resolved, conn: SSHConnection, timeout: Int = 30) async throws -> HTTPClient.Response {
        let result = try await conn.run(HTTPClient.curlCommand(r, timeout: timeout), timeout: .seconds(timeout + 10))
        // curl prints the meta line with status 000 when it couldn't connect; its reason is on stderr.
        if let response = HTTPClient.parseCurl(result.stdout), response.status > 0 { return response }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw SendError.server(message.isEmpty ? String(localized: "curl ended with exit code \(result.exitCode).") : message)
    }
}
