import Foundation

/// TCP ports something listens on, on the server — the candidates to open through a forwarded port.
public enum ListeningPorts {
    public struct Port: Sendable, Hashable, Identifiable {
        public var port: Int
        /// Listens only on the server's loopback (not reachable from outside without a tunnel).
        public var localOnly: Bool
        /// The program, if the server tells us (only for your own processes without root).
        public var process: String?
        public var id: Int { port }
    }

    /// `ss`, else `netstat` (BusyBox), else the kernel's own tables — works on minimal systems too.
    public static let command = "ss -ltnpH 2>/dev/null || netstat -ltnp 2>/dev/null || netstat -ltn 2>/dev/null || cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"

    public static func parse(_ output: String, hiding: Set<Int> = []) -> [Port] {
        var byPort: [Int: Port] = [:]
        for line in output.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4 else { continue }
            // /proc/net/tcp: "0: 0100007F:223D 00000000:0000 0A …" — hex address:port, state 0A = listening.
            if f[0].hasSuffix(":"), let hexPort = f[1].split(separator: ":").last, let port = Int(hexPort, radix: 16) {
                guard f[3] == "0A", !hiding.contains(port) else { continue }
                let addr = String(f[1].split(separator: ":").first ?? "")
                let loopback = addr == "0100007F" || addr == "00000000000000000000000001000000"
                var p = byPort[port] ?? Port(port: port, localOnly: loopback, process: nil)
                p.localOnly = p.localOnly && loopback
                byPort[port] = p
                continue
            }
            let local = f[3]
            guard let colon = local.lastIndex(of: ":"), let port = Int(local[local.index(after: colon)...]), !hiding.contains(port) else { continue }
            let address = String(local[..<colon])
            let loopback = address.hasPrefix("127.") || address == "[::1]" || address == "::1"
            let process = line.range(of: #"users:\(\("([^"]+)""#, options: .regularExpression)
                .map { String(line[$0]).replacingOccurrences(of: "users:((\"", with: "").replacingOccurrences(of: "\"", with: "") }
                ?? f.last.flatMap { last in last.range(of: #"^\d+/\S+$"#, options: .regularExpression).map { _ in String(last.split(separator: "/").last ?? "") } }
            if var existing = byPort[port] {
                existing.localOnly = existing.localOnly && loopback
                existing.process = existing.process ?? process
                byPort[port] = existing
            } else {
                byPort[port] = Port(port: port, localOnly: loopback, process: process)
            }
        }
        // Web-looking ports first, then by number.
        let webby: Set<Int> = [80, 443, 3000, 3001, 4000, 5000, 5173, 8000, 8080, 8081, 8443, 8888, 9000]
        return byPort.values.sorted { (webby.contains($0.port) ? 0 : 1, $0.port) < (webby.contains($1.port) ? 0 : 1, $1.port) }
    }

    /// `http://localhost:3000/path` → 3000, for links in agent replies.
    public static func localPort(in url: URL) -> Int? {
        guard let host = url.host?.lowercased(), ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url.port ?? (url.scheme == "https" ? 443 : 80)
    }
}
