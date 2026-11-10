import Foundation
import Network

/// Checks from this device whether TCP ports on a host accept connections — the outside view of a server.
public enum PortProbe {
    public static func isOpen(host: String, port: Int, timeout: Duration = .seconds(2)) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let result = OnceFlag()
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ open: Bool) {
                guard result.claim() else { return }
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                // `.waiting` can be a passing state (no route yet) — only a real failure or the timeout counts.
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            Task {
                try? await Task.sleep(for: timeout)
                finish(false)
            }
        }
    }

    /// Probes many ports at once; returns the open ones, sorted.
    public static func openPorts(host: String, ports: [Int], timeout: Duration = .seconds(2)) async -> [Int] {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for p in Set(ports) { group.addTask { (p, await isOpen(host: host, port: p, timeout: timeout)) } }
            var open: [Int] = []
            for await (p, ok) in group where ok { open.append(p) }
            return open.sorted()
        }
    }
}

/// A flag that can be claimed exactly once from any thread.
final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
