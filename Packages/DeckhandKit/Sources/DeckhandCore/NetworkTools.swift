import Foundation

/// Ping, traceroute, DNS, port and HTTP checks — from the server (its own tools) or from the phone — with readable
/// results that can go to an agent.
public enum NetworkTools {
    public enum Tool: String, Sendable, CaseIterable, Identifiable {
        case ping, traceroute, dns, port, http
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .ping: "Ping"
            case .traceroute: "Traceroute"
            case .dns: "DNS"
            case .port: "Port"
            case .http: "HTTP"
            }
        }
        /// The phone can't send ICMP or trace routes.
        public var onPhone: Bool { self != .traceroute }
    }

    /// A host name or an IP address (v4 or v6); nothing a shell could misread.
    public static func isValidTarget(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.count <= 253 && t.range(of: #"^[A-Za-z0-9.:\-\[\]]+$"#, options: .regularExpression) != nil && !t.hasPrefix("-")
    }

    /// `https://shop.example.com/x` → `shop.example.com` (the tools want a host).
    public static func host(from input: String) -> String {
        var t = input.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        if t.filter({ $0 == ":" }).count == 1, let colon = t.firstIndex(of: ":") { t = String(t[..<colon]) }
        return t
    }

    public static let dnsTypes = ["A", "AAAA", "MX", "TXT", "NS", "CNAME"]

    /// The server-side command. Output: the tool's own lines, plus `@@` summary lines the parser reads.
    public static func serverCommand(_ tool: Tool, target raw: String, port: Int = 443, dnsType: String = "A", url: String? = nil) -> String {
        let t = ShellQuote.quote(host(from: raw))
        switch tool {
        case .ping:
            return "command -v ping >/dev/null 2>&1 || { echo '@@missing ping'; exit 0; }; ping -c 4 -W 2 \(t) 2>&1 || ping -c 4 \(t) 2>&1; true"
        case .traceroute:
            return """
            if command -v tracepath >/dev/null 2>&1; then tracepath -n -m 20 \(t) 2>&1
            elif command -v traceroute >/dev/null 2>&1; then traceroute -n -m 20 -w 2 \(t) 2>&1
            elif command -v mtr >/dev/null 2>&1; then mtr -n -r -c 1 \(t) 2>&1
            else echo '@@missing traceroute'; fi; true
            """
        case .dns:
            let type = dnsTypes.contains(dnsType) ? dnsType : "A"
            return """
            if command -v dig >/dev/null 2>&1; then dig +short \(type) \(t) | sed 's/^/@@answer /'; echo "@@server $(dig \(type) \(t) | sed -n 's/^;; SERVER: //p')"
            elif command -v host >/dev/null 2>&1; then host -t \(type) \(t) 2>&1 | sed 's/^/@@answer /'
            else getent ahosts \(t) | awk '{print $1}' | sort -u | sed 's/^/@@answer /'; fi; true
            """
        case .port:
            let p = max(1, min(port, 65535))
            return """
            s=$(date +%s%N 2>/dev/null)
            if command -v nc >/dev/null 2>&1; then nc -z -w 5 \(t) \(p) >/dev/null 2>&1; r=$?
            else timeout 5 bash -c "</dev/tcp/\(host(from: raw))/\(p)" >/dev/null 2>&1; r=$?; fi
            e=$(date +%s%N 2>/dev/null); ms=; [ -n "$s" ] && [ -n "$e" ] && ms=$(( (e - s) / 1000000 ))
            [ $r = 0 ] && echo "@@port open $ms" || echo "@@port closed $ms"
            """
        case .http:
            let u = url.flatMap { $0.hasPrefix("http") ? $0 : nil } ?? "https://\(host(from: raw))/"
            return "curl -s -o /dev/null -L --max-time 20 -w '\\n@@http %{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{remote_ip} %{num_redirects}\\n' \(ShellQuote.quote(u)) 2>&1; true"
        }
    }

    public struct Result: Sendable, Hashable {
        /// Short readable lines: "4 of 4 replies, 12.3 ms average".
        public var summary: [String] = []
        public var ok: Bool?
        /// The tool's output without the `@@` lines.
        public var raw = ""
        public init(summary: [String] = [], ok: Bool? = nil, raw: String = "") { self.summary = summary; self.ok = ok; self.raw = raw }
    }

    public static func parse(_ tool: Tool, _ out: String) -> Result {
        var r = Result()
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        r.raw = lines.filter { !$0.hasPrefix("@@") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        switch tool {
        case .ping:
            if out.contains("@@missing") { r.ok = false; r.summary.append("No ping tool on this server — try it from this iPhone") }
            if let m = out.range(of: #"(\d+) packets transmitted, (\d+) (packets )?received"#, options: .regularExpression) {
                let n = out[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if n.count >= 2 { r.summary.append("\(n[1]) of \(n[0]) replies"); r.ok = n[1] > 0 }
            }
            if let m = out.range(of: #"= [\d.]+/[\d.]+/[\d.]+"#, options: .regularExpression) {
                let v = out[m].dropFirst(2).split(separator: "/")
                if v.count == 3 { r.summary.append("\(v[1]) ms average (\(v[0])–\(v[2]) ms)") }
            }
            if r.ok == nil && (out.contains("unknown host") || out.contains("Name or service not known")) { r.ok = false; r.summary.append("The name doesn't resolve") }
        case .traceroute:
            if out.contains("@@missing") { r.ok = false; r.summary.append("No traceroute tool on this server (tracepath, traceroute or mtr)") }
            else {
                let hops = lines.filter { $0.range(of: #"^\s*\d+[:?]?\s"#, options: .regularExpression) != nil }
                let numbers = Set(hops.compactMap { Int($0.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) })
                r.summary.append("\(numbers.count) hops")
                if let last = hops.last { r.summary.append("Last: " + last.trimmingCharacters(in: .whitespaces)) }
                r.ok = !hops.isEmpty
            }
        case .dns:
            let answers = lines.filter { $0.hasPrefix("@@answer ") }.map { String($0.dropFirst(9)) }.filter { !$0.isEmpty }
            r.summary = answers.isEmpty ? ["No records"] : answers
            if let s = lines.first(where: { $0.hasPrefix("@@server ") }), s.count > 9 { r.summary.append("Answered by \(s.dropFirst(9))") }
            r.ok = !answers.isEmpty && !answers.contains { $0.contains("not found") || $0.contains("NXDOMAIN") }
        case .port:
            if let l = lines.first(where: { $0.hasPrefix("@@port ") }) {
                let p = l.split(separator: " ")
                r.ok = p.count > 1 && p[1] == "open"
                r.summary.append((r.ok == true ? "Open" : "Closed or filtered") + (p.count > 2 ? " (\(p[2]) ms)" : ""))
            }
        case .http:
            if let l = lines.first(where: { $0.hasPrefix("@@http ") }) {
                let f = l.split(separator: " ").map(String.init)
                if f.count >= 9, let code = Int(f[1]) {
                    func ms(_ s: String) -> String { Double(s).map { String(format: "%.0f ms", $0 * 1000) } ?? s }
                    r.ok = (200..<400).contains(code)
                    r.summary = [code == 0 ? "No answer" : "Status \(code)", "Total \(ms(f[6]))",
                                 "DNS \(ms(f[2])) · connect \(ms(f[3])) · TLS \(ms(f[4])) · first byte \(ms(f[5]))"]
                    if !f[7].isEmpty { r.summary.append("Address \(f[7])") }
                    if f[8] != "0" { r.summary.append("\(f[8]) redirects") }
                }
            }
        }
        return r
    }

    /// For "Ask an agent": what was run, where, and what came back.
    public static func agentPrompt(tool: Tool, target: String, fromPhone: Bool, result: Result) -> String {
        """
        I ran \(tool.title) for \(target) \(fromPhone ? "from my phone" : "on this server"). Explain what the result means and, if \
        something is wrong, find the cause from this server. Don't change anything without asking.

        \(result.summary.joined(separator: "\n"))

        \(String(result.raw.suffix(3_000)))
        """
    }

    // MARK: From the phone

    /// DNS over HTTPS (Cloudflare's JSON API): the answers' data fields.
    public static func parseDoH(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]] else { return [] }
        return answers.compactMap { $0["data"] as? String }
    }
}
