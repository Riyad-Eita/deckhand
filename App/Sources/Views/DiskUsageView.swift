import DeckhandCore
import SwiftUI

/// Where the space goes, folder by folder, with cleanup suggestions and careful deleting.
struct DiskUsageView: View {
    let server: Server
    var path: String = "/"
    @State var asRoot = false
    var isTop: Bool { path == "/" }

    @Environment(Connections.self) private var connections
    @State private var root = RootRunner()
    @State private var scan: DiskUsage.Scan?
    @State private var suggestions: [DiskUsage.Suggestion] = []
    @State private var home = ""
    @State private var error: String?
    @State private var busy = false
    @State private var confirmDelete: DiskUsage.Entry?
    @State private var confirmCleanup: DiskUsage.Suggestion?
    @State private var message: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if isTop {
                Section {
                    if !home.isEmpty {
                        NavigationLink { DiskUsageView(server: server, path: home, asRoot: asRoot) } label: {
                            Label("Your home folder", systemImage: "house")
                        }
                        .accessibilityIdentifier("disk.home")
                    }
                    Toggle("Include folders only root can read (sudo)", isOn: $asRoot)
                        .onChange(of: asRoot) { Task { await load() } }
                }
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { s in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LocalizedStringKey(s.title))
                                    Text(LocalizedStringKey(s.detail)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 6) {
                                    Text(ByteFormat.kb(s.kilobytes)).font(.subheadline.monospacedDigit().weight(.semibold))
                                    Button("Clean up") { confirmCleanup = s }.buttonStyle(.bordered).controlSize(.small)
                                        .accessibilityIdentifier("cleanup.\(s.id)")
                                }
                            }
                        }
                    } header: {
                        Text("Can be cleaned up")
                    }
                }
            }
            if let scan {
                Section {
                    if scan.missing { Text("This folder doesn't exist anymore.").foregroundStyle(.secondary) }
                    ForEach(scan.entries) { entry in row(entry, total: max(scan.totalKB, 1)) }
                } header: {
                    HStack {
                        Text(scan.directory)
                        Spacer()
                        Text(ByteFormat.kb(scan.totalKB)).monospacedDigit()
                    }
                } footer: {
                    Text("Sizes on this disk only (mounted drives are skipped). Swipe to delete.")
                }
            } else if busy {
                HStack { Spacer(); ProgressView("Measuring…"); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle(isTop ? String(localized: "Disk usage") : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(isTop ? .large : .inline)
        .task { if scan == nil { await load() } }
        .refreshable { await load() }
        .sudoPassword(root, server: server)
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")” (\(ByteFormat.kb(confirmDelete?.kilobytes ?? 0)))?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let e = confirmDelete { Task { await delete(e) } } }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Clean up “\(confirmCleanup.map { String(localized: String.LocalizationValue($0.title)) } ?? "")”?",
                            isPresented: Binding(get: { confirmCleanup != nil }, set: { if !$0 { confirmCleanup = nil } }), titleVisibility: .visible) {
            Button("Clean up", role: .destructive) { if let s = confirmCleanup { Task { await cleanup(s) } } }
        } message: {
            Text(confirmCleanup?.command ?? "").font(.caption.monospaced())
        }
    }

    @ViewBuilder private func row(_ entry: DiskUsage.Entry, total: Int64) -> some View {
        let content = HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? Theme.accent : .secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteFormat.kb(entry.kilobytes)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    Capsule().fill(Theme.accent.opacity(0.75))
                        .frame(width: max(2, g.size.width * CGFloat(entry.kilobytes) / CGFloat(total)))
                }
                .frame(height: 4)
            }
        }
        let protected = DiskUsage.protectionReason(entry.path, home: home)
        Group {
            if entry.isDirectory {
                NavigationLink { DiskUsageView(server: server, path: entry.path, asRoot: asRoot) } label: { content }
            } else {
                content
            }
        }
        .swipeActions {
            if protected == nil {
                Button("Delete") { confirmDelete = entry }.tint(.red)
            }
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            if home.isEmpty { home = try await conn.run("printf %s \"$HOME\"", timeout: .seconds(10)).stdout }
            if asRoot {
                guard await root.run(DiskUsage.scanCommand(path), on: server) else { return }
                scan = DiskUsage.parseScan(root.lines.joined(separator: "\n"))
            } else {
                scan = DiskUsage.parseScan(try await conn.run(DiskUsage.scanCommand(path), timeout: .seconds(120)).stdout)
            }
            if isTop {
                let r = try await conn.run(DiskUsage.suggestionsScript, timeout: .seconds(60))
                suggestions = DiskUsage.parseSuggestions(r.stdout, asRoot: true)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ entry: DiskUsage.Entry) async {
        guard DiskUsage.protectionReason(entry.path, home: home) == nil else { return }
        await run(DiskUsage.deleteCommand(entry.path), asRoot: asRoot)
        message = String(localized: "Deleted \(entry.name).")
        await load()
    }

    private func cleanup(_ s: DiskUsage.Suggestion) async {
        await run(s.command, asRoot: s.needsRoot)
        message = String(localized: "Cleaned up: \(String(localized: String.LocalizationValue(s.title))).")
        await load()
    }

    private func run(_ command: String, asRoot: Bool) async {
        if asRoot {
            await root.run(command, on: server)
            if case .failed(let m) = root.phase { error = m }
        } else if let conn = try? await connections.connection(for: server) {
            let r = try? await conn.run(command, timeout: .seconds(300))
            if let r, r.exitCode != 0 { error = r.stderr.isEmpty ? r.stdout : r.stderr }
        }
    }
}
