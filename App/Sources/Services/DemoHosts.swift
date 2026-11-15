import DeckhandSSH
import Foundation

/// Screen recordings: a public-looking demo address typed in the app can lead to a real test server.
/// DEBUG only — `DECKHAND_DEMO_HOSTMAP="demo.example.com=real-host:2222;…"`. Release builds connect as typed.
enum DemoHosts {
    static func endpoint(host: String, port: Int, username: String) -> SSHEndpoint {
        #if DEBUG
        for pair in (ProcessInfo.processInfo.environment["DECKHAND_DEMO_HOSTMAP"] ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].caseInsensitiveCompare(host) == .orderedSame else { continue }
            let target = parts[1].split(separator: ":").map(String.init)
            let mappedPort = target.count > 1 && port == 22 ? Int(target[1]) ?? port : port
            return SSHEndpoint(host: target[0], port: mappedPort, username: username)
        }
        #endif
        return SSHEndpoint(host: host, port: port, username: username)
    }
}
