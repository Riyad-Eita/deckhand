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
    func setPassword(_ password: String?, for server: Server) { passwords[server.id] = password }
}

/// Runs one root script for a screen: asks for the sudo password when needed and collects the output.
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
    private var pending: (script: String, server: Server)?
    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .running }
    var succeeded: Bool { phase == .finished(0) && failedStep == nil }

    func start(_ script: String, on server: Server) {
        pending = (script, server)
        lines = []; steps = []; failedStep = nil
        task?.cancel()
        task = Task { await run() }
    }

    func submitPassword() {
        guard let pending else { return }
        RootAccess.shared.setPassword(password, for: pending.server)
        password = ""
        start(pending.script, on: pending.server)
    }

    func cancel() {
        task?.cancel()
        if phase == .needsPassword || phase == .running { phase = .idle }
    }

    private func run() async {
        guard let (script, server) = pending else { return }
        phase = .running
        do {
            let conn = try await Connections.shared.connection(for: server)
            let access = try await RootAccess.shared.access(for: server, connection: conn)
            let password = RootAccess.shared.password(for: server)
            if access == .password && password == nil {
                phase = .needsPassword
                passwordPrompt = true
                return
            }
            for try await line in Sudo.run(script, on: conn, access: access, password: password) {
                switch line {
                case .output(let text):
                    switch ConfigChange.event(text) {
                    case .step(let s): steps.append(s)
                    case .failed(let s): failedStep = s
                    case .done: break
                    case .output(let t): lines.append(t)
                    }
                case .exit(let code):
                    phase = .finished(code)
                }
            }
            if phase == .running { phase = .failed(String(localized: "The command ended without a result.")) }
        } catch SudoError.wrongPassword {
            if let server = pending?.server { RootAccess.shared.setPassword(nil, for: server) }
            phase = .needsPassword
            lines.append(String(localized: "That sudo password didn't work."))
            passwordPrompt = true
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
