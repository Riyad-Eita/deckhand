import Foundation

/// One command on several servers: all at once, or one after another stopping at the first failure.
public enum FleetRun {
    public struct Target: Sendable {
        public var id: UUID
        public var shell: @Sendable () async throws -> any RemoteShell
        public init(id: UUID, shell: @escaping @Sendable () async throws -> any RemoteShell) { self.id = id; self.shell = shell }
    }

    public enum State: Sendable, Hashable {
        case waiting, running, skipped
        case done(exitCode: Int32, output: String, seconds: Double)
        case failed(String)

        public var ok: Bool? {
            switch self {
            case .done(let code, _, _): code == 0
            case .failed: false
            default: nil
            }
        }
    }

    /// Runs `command` on every target and reports each state change. With `stopOnFailure` the targets run one after
    /// another and the rest are skipped after the first failure (non-zero exit or connection error).
    public static func run(_ command: String, on targets: [Target], stopOnFailure: Bool, timeout: Duration = .seconds(300),
                           update: @escaping @Sendable (UUID, State) async -> Void) async {
        @Sendable func one(_ t: Target) async -> State {
            await update(t.id, .running)
            let start = Date()
            let state: State
            do {
                let shell = try await t.shell()
                let r = try await shell.run(command, timeout: timeout)
                let out = (r.stdout + (r.stderr.isEmpty ? "" : (r.stdout.isEmpty ? "" : "\n") + r.stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
                state = .done(exitCode: r.exitCode, output: String(out.suffix(20_000)), seconds: Date().timeIntervalSince(start))
            } catch {
                state = .failed(error.localizedDescription)
            }
            await update(t.id, state)
            return state
        }
        if stopOnFailure {
            var stopped = false
            for t in targets {
                if stopped { await update(t.id, .skipped); continue }
                if await one(t).ok == false { stopped = true }
            }
        } else {
            await withTaskGroup(of: Void.self) { group in
                for t in targets { group.addTask { _ = await one(t) } }
            }
        }
    }

    /// Commands worth running everywhere.
    public static let quickCommands: [(title: String, command: String)] = [
        ("Uptime and load", "uptime"),
        ("Disk space", "df -h / | tail -n 1"),
        ("Memory", "free -h | sed -n 2p"),
        ("Pending updates", "(apt list --upgradable 2>/dev/null | grep -c upgradable) || (dnf -q check-update 2>/dev/null | grep -c '^[a-zA-Z]') || echo n/a"),
        ("Failed services", "systemctl --failed --no-legend 2>/dev/null | wc -l"),
        ("Running containers", "docker ps -q 2>/dev/null | wc -l"),
        ("OS version", ". /etc/os-release 2>/dev/null && echo \"$PRETTY_NAME\" || uname -sr"),
    ]
}
