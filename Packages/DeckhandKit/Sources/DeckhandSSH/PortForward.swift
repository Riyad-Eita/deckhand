@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A local port on this device that tunnels every connection through SSH (direct-tcpip) to a port on the server —
/// so a web app that only listens on the server's localhost opens in the app's browser.
public final class PortForward: @unchecked Sendable {
    /// The port to open on this device: `http://127.0.0.1:<localPort>`.
    public let localPort: Int
    public let remotePort: Int
    private let server: Channel

    init(localPort: Int, remotePort: Int, server: Channel) {
        self.localPort = localPort
        self.remotePort = remotePort
        self.server = server
    }

    /// Why a tunnel can't be opened, in plain words.
    public enum Failure: Error, LocalizedError, Equatable {
        case notAllowed
        case nothingListening(Int)
        case other(String)

        public var errorDescription: String? {
            switch self {
            case .notAllowed: String(localized: "This server doesn't allow SSH port forwarding (AllowTcpForwarding no in sshd_config).")
            case .nothingListening(let p): String(localized: "Nothing answers on port \(p) on the server.")
            case .other(let m): m
            }
        }
    }

    static func start(client: SSHClient, remoteHost: String, remotePort: Int) async throws -> PortForward {
        // Try one channel first, so a server that forbids forwarding gets a clear message instead of a blank page.
        do {
            let probe = try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(targetHost: remoteHost, targetPort: remotePort,
                                                  originatorAddress: (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))!)
            ) { $0.eventLoop.makeSucceededVoidFuture() }
            try? await probe.close()
        } catch {
            let text = String(describing: error).lowercased()
            if text.contains("prohibit") || text.contains("reasoncode: 1") || text.contains("reason: 1") { throw Failure.notAllowed }
            if text.contains("connect failed") || text.contains("refused") || text.contains("reasoncode: 2") || text.contains("reason: 2") {
                throw Failure.nothingListening(remotePort)
            }
            throw Failure.other(String(describing: error))
        }
        // The SSH connection's own event loop: both ends of every relay live on one loop, as NIO requires.
        let bootstrap = ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            // Don't read from the browser until the SSH channel is up, or its first request would be lost.
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { local in
                // Each local connection gets its own SSH channel to the server's port.
                let settings = SSHChannelType.DirectTCPIP(
                    targetHost: remoteHost, targetPort: remotePort,
                    originatorAddress: (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))!)
                let promise = local.eventLoop.makePromise(of: Void.self)
                promise.completeWithTask {
                    let remote = try await client.createDirectTCPIPChannel(using: settings) { _ in
                        local.eventLoop.makeSucceededVoidFuture()
                    }
                    let (a, b) = GlueHandler.pair()
                    try await local.pipeline.addHandler(a).get()
                    try await remote.pipeline.addHandler(b).get()
                    try await local.setOption(.autoRead, value: true).get()
                }
                return promise.futureResult.flatMapError { _ in local.close() }
            }
        let server = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = server.localAddress?.port else { throw SSHError.notConnected }
        return PortForward(localPort: port, remotePort: remotePort, server: server)
    }

    public var url: URL { URL(string: "http://127.0.0.1:\(localPort)/")! }

    public func stop() {
        server.close(promise: nil)
    }

    deinit { server.close(promise: nil) }
}

/// Relays bytes between two channels (from the SwiftNIO examples, trimmed).
final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func pair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; partner = nil }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, case .inputClosed = e { partner?.partnerWriteEOF() } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerCloseFull() }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    private func partnerBecameWritable() {
        if pendingRead { pendingRead = false; context?.read() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable { context.read() } else { pendingRead = true }
    }
}
