import DeckhandCore
import DeckhandSSH
import Foundation
import Observation

/// How each server becomes root, and the sudo password for this app session (memory only, never stored).
@MainActor
final class RootAccess {
    static let shared = RootAccess()
    private var access: [UUID: SudoAccess] = [:]
    private var passwords: [UUID: String] = [:]

    func access(for server: Server, connection: SSHConnection) async throws -> SudoAccess {
        if let a = access[server.id] { return a }
        let a = Sudo.parseProbe(try await connection.run(Sudo.probeCommand, timeout: .seconds(15)).stdout)
        access[server.id] = a
        return a
    }

    func password(for server: Server) -> String? { passwords[server.id] }
    /// Forget what we know (e.g. after switching the server to another login user).
    func reset(_ server: Server) { access[server.id] = nil; passwords[server.id] = nil }
    func setPassword(_ password: String?, for server: Server) { passwords[server.id] = password }
}

/// Runs root scripts for a screen: asks for the sudo password when needed and collects the output.
@MainActor
@Observable
final class RootRunner {
    enum Phase: Equatable { case idle, needsPassword, running, finished(Int32), failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var lines: [String] = []
    /// `@@step` names seen so far, and the step that failed.
    private(set) var steps: [String] = []
    private(set) var failedStep: String?
    var passwordPrompt = false
    var password = ""
    private var passwordReply: CheckedContinuation<Bool, Never>?
    private var server: Server?
    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .running || phase == .needsPassword }
    var succeeded: Bool { phase == .finished(0) && failedStep == nil }

    /// Starts `script` in the background (for buttons).
    func start(_ script: String, on server: Server) {
        task?.cancel()
        task = Task { _ = await run(script, on: server) }
    }

    /// Runs `script` as root and waits for it. Returns true if it exited 0 without a failed step.
    /// `connection` overrides the server's current connection (e.g. a fresh login on a new port).
    @discardableResult
    func run(_ script: String, on server: Server, connection: SSHConnection? = nil, input: [String] = []) async -> Bool {
        self.server = server
        lines = []; steps = []; failedStep = nil
        phase = .running
        do {
            let conn: SSHConnection
            if let connection { conn = connection } else { conn = try await Connections.shared.connection(for: server) }
            let access = try await RootAccess.shared.access(for: server, connection: conn)
            while true {
                var password = RootAccess.shared.password(for: server)
                if access == .password && password == nil {
                    guard await askForPassword() else { phase = .idle; return false }
                    password = RootAccess.shared.password(for: server)
                }
                do {
                    for try await line in Sudo.run(script, on: conn, access: access, password: password, input: input) {
                        switch line {
                        case .output(let text):
                            switch ConfigChange.event(text) {
                            case .step(let s): steps.append(s)
                            case .failed(let s): failedStep = s
                            case .done, .guarded: break
                            case .output(let t): lines.append(t)
                            }
                        case .exit(let code):
                            phase = .finished(code)
                        }
                    }
                    break
                } catch SudoError.wrongPassword {
                    RootAccess.shared.setPassword(nil, for: server)
                    lines.append(String(localized: "That sudo password didn't work."))
                }
            }
            if phase == .running { phase = .failed(String(localized: "The command ended without a result.")) }
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
        return succeeded
    }

    private func askForPassword() async -> Bool {
        phase = .needsPassword
        passwordPrompt = true
        return await withCheckedContinuation { passwordReply = $0 }
    }

    func submitPassword() {
        guard let server else { return }
        RootAccess.shared.setPassword(password, for: server)
        password = ""
        phase = .running
        passwordReply?.resume(returning: true)
        passwordReply = nil
    }

    func cancel() {
        task?.cancel()
        passwordReply?.resume(returning: false)
        passwordReply = nil
        if phase == .needsPassword || phase == .running { phase = .idle }
    }
}
