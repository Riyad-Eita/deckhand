import DeckhandCore
import SwiftData
import SwiftUI

/// Copies a file or folder from this server straight to another one: a temporary transfer key, the target's pinned
/// host key, rsync with resume on the source as a background job, progress, retry — and the key removed afterwards.
struct ServerCopySheet: View {
    let source: Server
    let path: String
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @State private var targetID: UUID?
    @State private var destination = ""
    @State private var phase: Phase = .ready
    @State private var progress: ServerCopy.Progress?
    @State private var log = ""
    @State private var run: DetachedRun?
    @State private var plan: Plan?

    enum Phase: Equatable { case ready, preparing, copying, done, failed(String) }
    struct Plan { let target: Server; let copy: String; let tag: String }

    private var targets: [Server] { servers.filter { $0.id != source.id } }
    private var target: Server? { targets.first { $0.id == targetID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("From", value: "\(source.displayName): \(path)")
                } footer: {
                    Text("The copy goes straight from server to server — nothing passes through this iPhone.")
                }
                Section {
                    if targets.isEmpty { Text("Add another server first.").foregroundStyle(.secondary) }
                    Picker("To", selection: $targetID) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(targets) { Text($0.displayName).tag(UUID?.some($0.id)) }
                    }
                    .accessibilityIdentifier("copy.target")
                    TextField("Folder on the target", text: $destination).font(Theme.mono)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("copy.destination")
                } footer: {
                    if let t = target, t.pinnedHostKey == nil {
                        Text("Open \(t.displayName) once first, so Deckhand knows its host key.").foregroundStyle(.orange)
                    }
                }
                Section { status }
            }
            .navigationTitle("Copy to another server")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(phase == .preparing || phase == .copying)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .done ? "Done" : "Close") { dismiss() }.disabled(phase == .preparing)
                }
            }
            .onChange(of: targetID) { if let t = target { destination = t.workingDirectory == "~" ? "/home/\(t.username)" : t.workingDirectory } }
            .task(id: run?.id) { await follow() }
        }
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .ready:
            Button { Task { await start() } } label: { Label("Copy", systemImage: "arrow.right.doc.on.clipboard") }
                .disabled(target?.pinnedHostKey == nil || destination.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("copy.start")
        case .preparing:
            HStack { ProgressView(); Text("Setting up the transfer…").foregroundStyle(.secondary) }
        case .copying:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(progress?.percent ?? 0), total: 100)
                Text(progress.map { "\($0.percent) % · \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file)) · \($0.speed)" }
                     ?? String(localized: "Copying…")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("copy.progress")
        case .done:
            Label("Copied to \(destination) on \(target?.displayName ?? "")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).accessibilityIdentifier("copy.done")
        case .failed(let why):
            VStack(alignment: .leading, spacing: 8) {
                Label(why, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.subheadline)
                Button { Task { await start() } } label: { Label("Retry — picks up where it stopped", systemImage: "arrow.clockwise") }
                    .accessibilityIdentifier("copy.retry")
            }
        }
    }

    private func start() async {
        guard let t = target, let hostKey = t.pinnedHostKey else { return }
        phase = .preparing
        do {
            let src = try await connections.connection(for: source)
            let dst = try await connections.connection(for: t)
            let tgt = ServerCopy.Target(host: t.host, port: t.port, user: t.username, hostKey: hostKey)
            let prep = try await src.run(ServerCopy.prepareSourceCommand(target: tgt), timeout: .seconds(30)).stdout
            guard let pub = prep.split(separator: "\n").first(where: { $0.hasPrefix("@@pub ") }).map({ String($0.dropFirst(6)) }) else {
                phase = .failed(String(localized: "The source server couldn't create a transfer key (ssh-keygen missing?)."))
                return
            }
            let tag = ServerCopy.tag(source.id)
            let auth = try await dst.run(ServerCopy.authorizeCommand(publicKey: pub, tag: tag), timeout: .seconds(30)).stdout
            let rsync = prep.contains("@@tools rsync") && auth.contains("@@tools rsync")
            let copy = ServerCopy.copyCommand(source: path, target: tgt, destination: destination.trimmingCharacters(in: .whitespaces), useRsync: rsync)
            plan = Plan(target: t, copy: copy, tag: tag)
            let r = DetachedRun()
            _ = try await src.run(r.startCommand(copy, meta: .init(title: String(localized: "Copy to \(t.displayName)"), engine: "Copy", directory: path)),
                                  timeout: .seconds(30))
            progress = nil; log = ""
            phase = .copying
            run = r
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reads the job's output until it ends, then removes the transfer key from the target.
    private func follow() async {
        guard let run, let plan else { return }
        while !Task.isCancelled {
            if let conn = try? await connections.connection(for: source),
               let r = try? await conn.run("cat \(run.base).out 2>/dev/null | tail -n 200; echo; echo \"@@exit $(cat \(run.base).exit 2>/dev/null)\"", timeout: .seconds(30)) {
                log = r.stdout
                progress = ServerCopy.progress(r.stdout) ?? progress
                if let line = r.stdout.split(separator: "\n").last(where: { $0.hasPrefix("@@exit") }),
                   let code = Int(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    if let dst = try? await connections.connection(for: plan.target) {
                        _ = try? await dst.run(ServerCopy.revokeCommand(tag: plan.tag), timeout: .seconds(30))
                    }
                    phase = code == 0 ? .done
                        : .failed(ServerCopy.explain(r.stdout) ?? String(localized: "The copy stopped (exit \(code))."))
                    return
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
