import Foundation

/// A small API client: requests with headers, body and auth, grouped in collections, with environments whose
/// `{{variables}}` fill in URLs, headers, bodies and auth. Requests go out from the phone (URLSession) or from a
/// server's network (curl over SSH); both end in the same `HTTPResponse`.
public enum HTTPClient {
    public enum Method: String, Codable, CaseIterable, Sendable { case GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS }

    public enum Auth: Codable, Hashable, Sendable {
        case none
        case bearer(String)
        case basic(user: String, password: String)
        case header(name: String, value: String)
    }

    public struct Header: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var value: String
        public var enabled = true
        public init(name: String, value: String, enabled: Bool = true) { self.name = name; self.value = value; self.enabled = enabled }
    }

    public struct Request: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var method: Method = .GET
        public var url: String
        public var headers: [Header] = []
        public var body: String = ""
        public var auth: Auth = .none
        public init(name: String, method: Method = .GET, url: String, headers: [Header] = [], body: String = "", auth: Auth = .none) {
            self.name = name; self.method = method; self.url = url; self.headers = headers; self.body = body; self.auth = auth
        }
    }

    public struct Variable: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var value: String
        /// Secret values live in the Keychain; `value` is empty in the saved collection.
        public var secret = false
        public init(name: String, value: String, secret: Bool = false) { self.name = name; self.value = value; self.secret = secret }
    }

    public struct Environment: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var variables: [Variable] = []
        public init(name: String, variables: [Variable] = []) { self.name = name; self.variables = variables }
    }

    public struct Collection: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var requests: [Request] = []
        public var environments: [Environment] = []
        public var activeEnvironment: UUID?
        public init(name: String, requests: [Request] = [], environments: [Environment] = []) {
            self.name = name; self.requests = requests; self.environments = environments
        }
    }

    /// A request with variables filled in and auth turned into headers: what actually goes out.
    public struct Resolved: Hashable, Sendable {
        public var method: Method
        public var url: String
        public var headers: [(String, String)]
        public var body: String
        /// `{{names}}` that no variable filled.
        public var missing: [String]
        public static func == (a: Resolved, b: Resolved) -> Bool {
            a.method == b.method && a.url == b.url && a.body == b.body && a.missing == b.missing
                && a.headers.map { $0.0 + "\u{0}" + $0.1 } == b.headers.map { $0.0 + "\u{0}" + $0.1 }
        }
        public func hash(into h: inout Hasher) { h.combine(url); h.combine(body) }
    }

    public struct Response: Hashable, Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: String
        public var seconds: Double
        public var bytes: Int
        public init(status: Int, headers: [String: String], body: String, seconds: Double, bytes: Int) {
            self.status = status; self.headers = headers; self.body = body; self.seconds = seconds; self.bytes = bytes
        }

        public var isSuccess: Bool { (200..<300).contains(status) }

        /// The standard reason phrase ("OK", "Not Found"), or the class of the code.
        public var reason: String {
            let known: [Int: String] = [
                200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
                301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
                400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
                410: "Gone", 413: "Content Too Large", 415: "Unsupported Media Type", 422: "Unprocessable Content", 429: "Too Many Requests",
                500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
            ]
            if let r = known[status] { return r }
            switch status {
            case 200..<300: return "Success"
            case 300..<400: return "Redirect"
            case 400..<500: return "Client Error"
            default: return "Server Error"
            }
        }

        /// JSON bodies indented with sorted keys; anything else as it came.
        public var prettyBody: String {
            guard let data = body.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  obj is [Any] || obj is [String: Any],
                  let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let s = String(data: out, encoding: .utf8) else { return body }
            return s
        }
    }

    // MARK: - Variables

    /// Replaces `{{name}}` (spaces inside the braces allowed) with the variable's value; unknown names stay and
    /// are reported.
    public static func substitute(_ text: String, _ vars: [String: String], missing: inout Set<String>) -> String {
        guard text.contains("{{") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else { out += rest[open.lowerBound...]; return out }
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let v = vars[name] { out += v } else { out += rest[open.lowerBound..<close.upperBound]; missing.insert(name) }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    public static func resolve(_ r: Request, variables: [String: String]) -> Resolved {
        var missing = Set<String>()
        let sub = { (s: String) in substitute(s, variables, missing: &missing) }
        var headers = r.headers.filter { $0.enabled && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (sub($0.name).trimmingCharacters(in: .whitespaces), sub($0.value)) }
        switch r.auth {
        case .none: break
        case .bearer(let token): headers.append(("Authorization", "Bearer " + sub(token)))
        case .basic(let user, let password):
            headers.append(("Authorization", "Basic " + Data("\(sub(user)):\(sub(password))".utf8).base64EncodedString()))
        case .header(let name, let value): headers.append((sub(name), sub(value)))
        }
        let body = sub(r.body)
        // A JSON body without a content type gets one, like other API clients do.
        if !body.isEmpty, !headers.contains(where: { $0.0.lowercased() == "content-type" }), looksLikeJSON(body) {
            headers.append(("Content-Type", "application/json"))
        }
        var url = sub(r.url).trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty, !url.contains("://") { url = "https://" + url }
        return Resolved(method: r.method, url: url, headers: headers, body: body, missing: missing.sorted())
    }

    static func looksLikeJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("[") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil
    }

    // MARK: - From the server (curl)

    /// A curl command for the server. Body and headers go through stdin-free quoting; `--data-raw` so a body that
    /// starts with `@` isn't read as a file name. The last line carries status, time and size.
    public static func curlCommand(_ r: Resolved, timeout: Int = 30, insecure: Bool = false) -> String {
        var parts = ["curl", "-sS", "-i", "--max-time", String(timeout), "-X", r.method.rawValue]
        if r.method == .HEAD { parts = ["curl", "-sS", "-I", "--max-time", String(timeout)] }
        if insecure { parts.append("-k") }
        for (name, value) in r.headers { parts += ["-H", ShellQuote.quote("\(name): \(value)")] }
        if !r.body.isEmpty, r.method != .GET, r.method != .HEAD { parts += ["--data-raw", ShellQuote.quote(r.body)] }
        parts += ["-w", ShellQuote.quote("\n@@meta %{http_code} %{time_total} %{size_download}"), "--", ShellQuote.quote(r.url)]
        return "command -v curl >/dev/null 2>&1 || { echo 'curl is not installed on this server.' >&2; exit 127; }\n" + parts.joined(separator: " ")
    }

    /// Splits curl's `-i` output into the final header block, the body and the `@@meta` line. Interim responses
    /// (100 Continue) and proxy `Connection established` blocks are skipped.
    public static func parseCurl(_ out: String) -> Response? {
        var text = out
        var status = 0, seconds = 0.0, bytes = 0
        if let r = text.range(of: "\n@@meta ", options: .backwards) ?? (text.hasPrefix("@@meta ") ? text.range(of: "@@meta ") : nil) {
            let meta = text[r.upperBound...].split(separator: " ").map(String.init)
            if meta.count >= 3 { status = Int(meta[0]) ?? 0; seconds = Double(meta[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0; bytes = Int(meta[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
            text = String(text[..<r.lowerBound])
        } else { return nil }
        var headers: [String: String] = [:]
        while text.hasPrefix("HTTP/") {
            let sep = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n")
            let block = sep.map { String(text[..<$0.lowerBound]) } ?? text
            text = sep.map { String(text[$0.upperBound...]) } ?? ""
            let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            let code = lines.first.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) } ?? 0
            if (100..<200).contains(code) || lines.first?.lowercased().contains("connection established") == true { continue }
            headers = [:]
            for line in lines.dropFirst() {
                guard let c = line.firstIndex(of: ":") else { continue }
                headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
            break
        }
        return Response(status: status, headers: headers, body: text, seconds: seconds, bytes: bytes)
    }

    // MARK: - Paste a curl command

    /// Reads a pasted `curl …` command (as browsers' "Copy as cURL" give it) into a request.
    public static func importCurl(_ command: String) -> Request? {
        let words = shellWords(command.replacingOccurrences(of: "\\\n", with: " ").replacingOccurrences(of: "\\\r\n", with: " "))
        guard words.first == "curl" else { return nil }
        var r = Request(name: "Imported", url: "")
        var explicitMethod: Method?
        var i = 1
        func next() -> String? { i += 1; return i < words.count ? words[i] : nil }
        while i < words.count {
            let w = words[i]
            switch w {
            case "-X", "--request": if let m = next() { explicitMethod = Method(rawValue: m.uppercased()) }
            case "-H", "--header":
                if let h = next(), let c = h.firstIndex(of: ":") {
                    let name = h[..<c].trimmingCharacters(in: .whitespaces), value = h[h.index(after: c)...].trimmingCharacters(in: .whitespaces)
                    if name.lowercased() == "authorization", value.lowercased().hasPrefix("bearer ") { r.auth = .bearer(String(value.dropFirst(7))) }
                    else { r.headers.append(Header(name: name, value: value)) }
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--json":
                if let d = next() { r.body = r.body.isEmpty ? d : r.body + "&" + d }
                if w == "--json", !r.headers.contains(where: { $0.name.lowercased() == "content-type" }) {
                    r.headers.append(Header(name: "Content-Type", value: "application/json"))
                }
            case "-u", "--user":
                if let u = next() {
                    let p = u.split(separator: ":", maxSplits: 1).map(String.init)
                    r.auth = .basic(user: p.first ?? "", password: p.count > 1 ? p[1] : "")
                }
            case "-I", "--head": explicitMethod = .HEAD
            case "--url": if let u = next() { r.url = u }
            case "-o", "--output", "-w", "--write-out", "-m", "--max-time", "--connect-timeout", "-A", "--user-agent", "-e", "--referer", "-b", "--cookie":
                _ = next()
            default:
                if !w.hasPrefix("-"), r.url.isEmpty { r.url = w }
            }
            i += 1
        }
        guard !r.url.isEmpty else { return nil }
        r.method = explicitMethod ?? (r.body.isEmpty ? .GET : .POST)
        if let u = URL(string: r.url), let host = u.host() { r.name = "\(r.method.rawValue) \(host)\(u.path())" }
        return r
    }

    /// Splits a command line like a POSIX shell: single and double quotes, backslash escapes, `$'…'` strings.
    static func shellWords(_ s: String) -> [String] {
        var words: [String] = [], cur = "", inWord = false
        var chars = Array(s)[...]
        while let c = chars.popFirst() {
            switch c {
            case " ", "\t", "\n", "\r":
                if inWord { words.append(cur); cur = ""; inWord = false }
            case "'":
                inWord = true
                while let d = chars.popFirst(), d != "'" { cur.append(d) }
            case "$" where chars.first == "'":
                inWord = true; chars.removeFirst()
                while let d = chars.popFirst(), d != "'" {
                    if d == "\\", let e = chars.popFirst() {
                        switch e { case "n": cur.append("\n"); case "t": cur.append("\t"); default: cur.append(e) }
                    } else { cur.append(d) }
                }
            case "\"":
                inWord = true
                while let d = chars.popFirst(), d != "\"" {
                    if d == "\\", let e = chars.first, "\"\\$`".contains(e) { cur.append(e); chars.removeFirst() } else { cur.append(d) }
                }
            case "\\":
                inWord = true
                if let e = chars.popFirst() { cur.append(e) }
            default:
                inWord = true; cur.append(c)
            }
        }
        if inWord { words.append(cur) }
        return words
    }
}
