@preconcurrency import Citadel
import Crypto
import DeckhandCore
import Foundation
import NIOCore
import NIOSSH

public enum SSHCredential: Sendable, Hashable {
    case password(String)
    /// OpenSSH private key (`-----BEGIN OPENSSH PRIVATE KEY-----`), RSA or Ed25519.
    case privateKey(String, passphrase: String?)
}

public struct SSHEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}

public enum SSHError: Error, LocalizedError, Sendable {
    case unsupportedKey(String)
    case hostKeyRejected(fingerprint: String)
    case hostKeyChanged(expected: String, got: String)
    case notConnected
    case timedOut(seconds: Int)
    /// No answer from host:port within the connect timeout (offline, wrong address or port, firewall).
    case unreachable(host: String, port: Int)
    /// Actively refused: nothing listens on that port.
    case refused(host: String, port: Int)
    /// The name doesn't resolve.
    case unknownHost(String)
    /// The server answered but didn't accept the user / password / key.
    case signInRejected(user: String)
    /// The connection dropped while working.
    case connectionLost

    public var errorDescription: String? {
        switch self {
        case .unsupportedKey(let s): String(localized: "This private key is not supported: \(s)")
        case .hostKeyRejected(let f): String(localized: "Host key \(f) was not trusted.")
        case .hostKeyChanged(let expected, let got):
            String(localized: "The server's host key changed (expected \(expected), got \(got)). This can mean someone is intercepting the connection.")
        case .notConnected: String(localized: "Not connected to the server.")
        case .timedOut(let s): String(localized: "The command did not finish within \(s) s.")
        case .unreachable(let h, let p): String(localized: "No answer from \(h) on port \(p).")
        case .refused(let h, let p): String(localized: "\(h) refused the connection on port \(p).")
        case .unknownHost(let h): String(localized: "The address \(h) can't be found.")
        case .signInRejected(let u): String(localized: "The server didn't accept the login for \(u).")
        case .connectionLost: String(localized: "The connection to the server was lost.")
        }
    }

    /// Turns NIO / Citadel errors (whose own descriptions read "NIOCore.ChannelError error 0") into plain ones.
    static func translate(_ error: Error, host: String, port: Int, user: String) -> Error {
        if error is SSHError || error is CancellationError { return error }
        let text = String(describing: error)
        let lower = text.lowercased()
        if lower.contains("allauthenticationoptionsfailed") || lower.contains("authentication failed") {
            return SSHError.signInRejected(user: user)
        }
        if lower.contains("dns") || lower.contains("unknownhost") || lower.contains("nodename nor servname") || lower.contains("name or service not known") {
            return SSHError.unknownHost(host)
        }
        if lower.contains("connection refused") || lower.contains("econnrefused") || lower.contains("errno: 61") || lower.contains("errno: 111") {
            return SSHError.refused(host: host, port: port)
        }
        if lower.contains("connect timeout") || lower.contains("connecttimeout") || lower.contains("host is down")
            || lower.contains("network is unreachable") || lower.contains("no route to host") || lower.contains("timed out") {
            return SSHError.unreachable(host: host, port: port)
        }
        if lower.contains("ioonclosedchannel") || lower.contains("alreadyclosed") || lower.contains("connection reset")
            || lower.contains("broken pipe") || lower.contains("eof") || lower.contains("channel closed") {
            return SSHError.connectionLost
        }
        return error
    }
}

public enum SSHKeys {
    /// A fresh Ed25519 key pair: OpenSSH private key text and the `ssh-ed25519 AAAA… comment` line.
    public static func generateEd25519(comment: String) -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        // Citadel pads the private section wrongly for some comment lengths, so the private key carries no comment.
        return (key.makeSSHRepresentation(), publicKeyLine(for: key, comment: comment))
    }

    public static func publicKeyLine(for key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) + " " + comment
    }

    /// Public key line for a stored private key, if it can be derived.
    public static func publicKeyLine(privateKey: String, comment: String) -> String? {
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: privateKey) {
            return publicKeyLine(for: key, comment: comment)
        }
        return nil
    }

    /// OpenSSH-style `SHA256:…` fingerprint of a public key line (`type base64 [comment]`).
    public static func fingerprint(openSSHPublicKey line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return line }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + digest
    }

    static func authenticationMethod(username: String, credential: SSHCredential) throws -> SSHAuthenticationMethod {
        switch credential {
        case .password(let p):
            return .passwordBased(username: username, password: p)
        case .privateKey(let text, let passphrase):
            let pass = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            let type = try? SSHKeyDetection.detectPrivateKeyType(from: text)
            switch type {
            case .some(.ed25519):
                return .ed25519(username: username, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: pass))
            case .some(.rsa):
                return .rsa(username: username, privateKey: try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: pass))
            default:
                throw SSHError.unsupportedKey(type.map(\.description) ?? "unknown format (use an OpenSSH Ed25519 or RSA key)")
            }
        }
    }
}

/// Validates the server key against a pinned key, or asks once (trust on first use).
final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let pinned: String?
    let decide: @Sendable (_ openSSHKey: String, _ fingerprint: String) async -> Bool
    private let lock = NSLock()
    private var _seen: String?
    var seen: String? { lock.withLock { _seen } }

    init(pinned: String?, decide: @escaping @Sendable (String, String) async -> Bool) {
        self.pinned = pinned
        self.decide = decide
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        lock.withLock { _seen = line }
        if let pinned {
            if pinned == line { validationCompletePromise.succeed(()) } else {
                validationCompletePromise.fail(SSHError.hostKeyChanged(
                    expected: SSHKeys.fingerprint(openSSHPublicKey: pinned), got: SSHKeys.fingerprint(openSSHPublicKey: line)))
            }
            return
        }
        let decide = self.decide
        Task {
            let fingerprint = SSHKeys.fingerprint(openSSHPublicKey: line)
            if await decide(line, fingerprint) { validationCompletePromise.succeed(()) } else {
                validationCompletePromise.fail(SSHError.hostKeyRejected(fingerprint: fingerprint))
            }
        }
    }
}

/// One SSH connection to a server. Runs commands for the agent and opens terminal sessions.
public actor SSHConnection: StreamingShell {
    public let endpoint: SSHEndpoint
    private let credential: SSHCredential
    private var client: SSHClient?
    /// The server's host key line after the first successful connect. Store it to pin the host.
    public private(set) var hostKey: String?

    public init(endpoint: SSHEndpoint, credential: SSHCredential) {
        self.endpoint = endpoint
        self.credential = credential
    }

    public var isConnected: Bool { client?.isConnected ?? false }

    /// Connects. `pinnedHostKey` is the stored key from an earlier connect; without it `trustNewHostKey` decides.
    public func connect(
        pinnedHostKey: String?,
        trustNewHostKey: @escaping @Sendable (_ key: String, _ fingerprint: String) async -> Bool
    ) async throws {
        if let client, client.isConnected { return }
        let (username, credential) = (endpoint.username, credential)
        _ = try SSHKeys.authenticationMethod(username: username, credential: credential) // surface key errors early
        let check = HostKeyCheck(pinned: pinnedHostKey, decide: trustNewHostKey)
        var settings = SSHClientSettings(
            host: endpoint.host, port: endpoint.port,
            authenticationMethod: {
                (try? SSHKeys.authenticationMethod(username: username, credential: credential))
                    ?? .passwordBased(username: username, password: "")
            }, hostKeyValidator: .custom(check))
        settings.connectTimeout = .seconds(15)
        do {
            client = try await SSHClient.connect(to: settings)
        } catch {
            throw SSHError.translate(error, host: endpoint.host, port: endpoint.port, user: endpoint.username)
        }
        hostKey = check.seen
    }

    public func disconnect() async {
        try? await client?.close()
        client = nil
    }

    /// Uploads `data` into `directory` (may start with `~`) as `name`, never overwriting: `photo.jpg` becomes
    /// `photo-2.jpg` if needed. Uses SFTP, or base64 chunks over exec when the server has no SFTP.
    /// Returns the absolute path. `progress` gets 0…1.
    /// `commandLineFallback` false: fail instead of sending the data as command lines (for secrets, which must
    /// never show up in a process list).
    public func upload(
        _ data: Data, named name: String, into directory: String, useSFTP: Bool = true, commandLineFallback: Bool = true,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let dir = ServerTools.shellPath(directory)
        let target = try await run("""
            mkdir -p \(dir) && cd \(dir) && n=\(ShellQuote.quote(safe.isEmpty ? "upload" : safe)); b="${n%.*}"; e="${n##*.}"
            [ "$b" = "$n" ] && e="" || e=".$e"; f="$n"; i=2
            while [ -e "$f" ]; do f="$b-$i$e"; i=$((i+1)); done; printf '%s/%s' "$(pwd)" "$f"
            """, timeout: .seconds(20))
        let path = target.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.exitCode == 0, path.hasPrefix("/") else { throw SSHError.notConnected }
        let chunk = 32 * 1024
        do {
            guard useSFTP else { throw SSHError.notConnected }
            let sftp = try await connectedClient().openSFTP()
            defer { Task { try? await sftp.close() } }
            try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunk, data.count)
                    try await file.write(ByteBuffer(bytes: data[offset..<end]), at: UInt64(offset))
                    offset = end
                    progress(Double(offset) / Double(max(data.count, 1)))
                }
            }
        } catch {
            guard commandLineFallback else { throw SSHError.unsupportedKey("This server has no SFTP, so secrets can't be written safely.") }
            // No SFTP subsystem: send base64 in pieces small enough for a command line.
            let piece = 48 * 1024
            _ = try await run(": > \(ShellQuote.quote(path))", timeout: .seconds(20))
            var offset = 0
            while offset < data.count {
                let end = min(offset + piece, data.count)
                let b64 = data[offset..<end].base64EncodedString()
                let r = try await run("printf '%s' '\(b64)' | base64 -d >> \(ShellQuote.quote(path))", timeout: .seconds(60))
                guard r.exitCode == 0 else { throw SSHError.unsupportedKey("Upload failed: \(r.stderr)") }
                offset = end
                progress(Double(offset) / Double(max(data.count, 1)))
            }
        }
        progress(1)
        return path
    }

    /// Forwards `127.0.0.1:<random port>` on this device to `remoteHost:remotePort` as seen from the server.
    public func forward(remoteHost: String = "127.0.0.1", remotePort: Int) async throws -> PortForward {
        try await PortForward.start(client: try connectedClient(), remoteHost: remoteHost, remotePort: remotePort)
    }

    private func connectedClient() throws -> SSHClient {
        guard let client, client.isConnected else { throw SSHError.notConnected }
        return client
    }

    /// Runs `command` with bash as a login shell so PATH matches what the user sees in a terminal.
    public func run(_ command: String, timeout: Duration) async throws -> CommandResult {
        let client = try connectedClient()
        let seconds = max(Int(timeout.components.seconds), 1)
        let full = "timeout -k 5 \(seconds) bash -lc \(ShellQuote.quote(command))"
        var stdout = ByteBuffer(), stderr = ByteBuffer()
        var exitCode: Int32 = 0
        let limit = 4 * 1024 * 1024
        do {
            for try await chunk in try await client.executeCommandStream(full) {
                switch chunk {
                case .stdout(var b) where stdout.readableBytes < limit: stdout.writeBuffer(&b)
                case .stderr(var b) where stderr.readableBytes < limit: stderr.writeBuffer(&b)
                default: break
                }
            }
        } catch let failed as SSHClient.CommandFailed {
            exitCode = Int32(truncatingIfNeeded: failed.exitCode)
        } catch {
            throw SSHError.translate(error, host: endpoint.host, port: endpoint.port, user: endpoint.username)
        }
        if exitCode == 124 { stderr.writeString("\n[timed out after \(seconds) s]") }
        return CommandResult(stdout: String(buffer: stdout), stderr: String(buffer: stderr), exitCode: exitCode)
    }

    /// Streams stdout lines of a long-running command (login shell, no timeout). Cancelling stops reading.
    public nonisolated func streamLines(_ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try await self.connectedClient()
                    var pending = Data()
                    var stderr = ""
                    do {
                        for try await chunk in try await client.executeCommandStream("bash -lc \(ShellQuote.quote(command))") {
                            try Task.checkCancellation()
                            switch chunk {
                            case .stdout(let b):
                                pending.append(Data(buffer: b))
                                while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                                    let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                                    pending.removeSubrange(pending.startIndex...nl)
                                    if !line.isEmpty { continuation.yield(line) }
                                }
                            case .stderr(let b):
                                if stderr.count < 20_000 { stderr += String(buffer: b) }
                            }
                        }
                    } catch let failed as SSHClient.CommandFailed {
                        if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                        let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000)
                        throw CLIError(tail.isEmpty ? "Command failed with exit code \(failed.exitCode)." : String(tail))
                    }
                    if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Starts `command` (login shell) and exchanges lines with its stdin/stdout, e.g. a stdio MCP server.
    public func openChannel(_ command: String) throws -> any LineChannel {
        SSHLineChannel(client: try connectedClient(), command: "bash -lc \(ShellQuote.quote(command))")
    }

    /// Opens an interactive PTY shell (optionally running `command`, e.g. `tmux new -A -s main`).
    public func openTerminal(cols: Int, rows: Int, term: String = "xterm-256color") throws -> TerminalSession {
        TerminalSession(client: try connectedClient(), cols: cols, rows: rows, term: term)
    }
}

/// A live PTY. Read `output`, send keystrokes with `send`, report size changes with `resize`.
public final class TerminalSession: @unchecked Sendable {
    public let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var writer: TTYStdinWriter?
    private var pending: [Data] = []
    private var task: Task<Void, Never>?
    public private(set) var closedError: Error?

    init(client: SSHClient, cols: Int, rows: Int, term: String) {
        (output, continuation) = AsyncStream.makeStream(of: Data.self)
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: term, terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([.ECHO: 1]))
        task = Task { [weak self] in
            do {
                try await client.withPTY(request) { inbound, outbound in
                    self?.attach(outbound)
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let b), .stderr(let b): self?.continuation.yield(Data(buffer: b))
                        }
                    }
                }
            } catch {
                self?.closedError = error
            }
            self?.continuation.finish()
        }
    }

    private func attach(_ writer: TTYStdinWriter) {
        let queued: [Data] = lock.withLock {
            self.writer = writer
            defer { pending = [] }
            return pending
        }
        for data in queued { send(data) }
    }

    public func send(_ data: Data) {
        let writer: TTYStdinWriter? = lock.withLock {
            if self.writer == nil { pending.append(data) }
            return self.writer
        }
        guard let writer else { return }
        Task { try? await writer.write(ByteBuffer(data: data)) }
    }

    public func send(_ text: String) { send(Data(text.utf8)) }

    public func resize(cols: Int, rows: Int) {
        guard let writer = lock.withLock({ self.writer }) else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    public func close() {
        task?.cancel()
        continuation.finish()
    }
}

/// A remote process's stdin/stdout as lines.
final class SSHLineChannel: LineChannel, @unchecked Sendable {
    let lines: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var writer: TTYStdinWriter?
    private var queued: [String] = []
    private var task: Task<Void, Never>?

    init(client: SSHClient, command: String) {
        (lines, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let buffer = LineBuffer()
        task = Task { [weak self] in
            do {
                try await client.withExec(command) { inbound, outbound in
                    self?.attach(outbound)
                    for try await chunk in inbound {
                        if case .stdout(let b) = chunk {
                            for line in buffer.append(Data(buffer: b)) { self?.continuation.yield(line) }
                        }
                    }
                }
                self?.continuation.finish()
            } catch {
                self?.continuation.finish(throwing: error)
            }
        }
    }

    private func attach(_ writer: TTYStdinWriter) {
        let pending: [String] = lock.withLock {
            self.writer = writer
            defer { queued = [] }
            return queued
        }
        for line in pending { Task { try? await writer.write(ByteBuffer(string: line + "\n")) } }
    }

    func send(_ line: String) async throws {
        let writer: TTYStdinWriter? = lock.withLock {
            if self.writer == nil { queued.append(line) }
            return self.writer
        }
        try await writer?.write(ByteBuffer(string: line + "\n"))
    }

    func close() {
        task?.cancel()
        continuation.finish()
    }
}

extension SSHConnection: ChannelShell {}
