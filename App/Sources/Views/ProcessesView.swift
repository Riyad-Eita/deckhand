import DeckhandCore
import SwiftUI

/// Running processes like top: CPU over the last second, memory, search, end with confirmation.
/// Refreshes every few seconds while visible.
struct ProcessesView: View {
    let server: Server

    @Environment(Connections.self) private var connections
    @AppStorage("processes.sort") private var sort: ProcessSort = .cpu
    @AppStorage("processes.kernel") private var showKernel = false
    @State private var snapshot: ProcessSnapshot?
    @State private var error: String?
    @State private var notice: String?
    @State private var query = ""
    @State private var ending: ProcessInfoRow?
    @State private var investigatePrompt: String?
    @State private var root = RootRunner()

    private var rows: [ProcessInfoRow] {
        Processes.sorted(snapshot?.processes ?? [], by: sort, query: query, showKernel: showKernel)
    }

    var body: some View {
        List {
            Section {
                Picker("Sort by", selection: $sort) {
                    Text("CPU").tag(ProcessSort.cpu)
                    Text("Memory").tag(ProcessSort.memory)
                    Text("Name").tag(ProcessSort.name)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            if let notice {
                Text(notice).foregroundStyle(.secondary).font(.footnote)
            }
            if let snapshot {
                Section {
                    ForEach(rows.prefix(300)) { p in
                        ProcessRow(process: p, mine: p.user == snapshot.me)
                            .contextMenu { menu(for: p) }
                            .swipeActions(edge: .trailing) {
                                if canEnd(p) {
                                    Button { ending = p } label: { Label("End", systemImage: "xmark.circle") }.tint(.red)
                                }
                            }
                    }
                } header: {
                    Text("\(rows.count) processes · \(snapshot.cores) cores").textCase(nil)
                } footer: {
                    Text("CPU is measured over one second; 100 % is one full core.")
                }
            }
        }
        .overlay { if snapshot == nil && error == nil { ProgressView() } }
        .searchable(text: $query, prompt: "Search command, user or PID")
        .navigationTitle("Processes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle(isOn: $showKernel) { Label("Show Kernel Threads", systemImage: "cpu") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Process Options")
            }
        }
        .confirmationDialog(
            ending.map { String(localized: "End “\($0.name)” (PID \(String($0.pid)))?") } ?? "",
            isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
            titleVisibility: .visible
        ) {
            if let p = ending {
                Button("End Process", role: .destructive) { end(p, force: false) }
                Button("Force Quit", role: .destructive) { end(p, force: true) }
            }
        } message: {
            if let p = ending {
                Text(p.user == snapshot?.me
                     ? "“End” asks it to quit and forces it after 5 seconds. Unsaved work in it is lost."
                     : "It belongs to \(p.user) — Deckhand asks for your sudo password. Unsaved work in it is lost.")
            }
        }
        .sudoPassword(root, server: server)
        .investigate(on: server, prompt: $investigatePrompt)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder
    private func menu(for p: ProcessInfoRow) -> some View {
        Button {
            investigatePrompt = "On this server, the process \(p.name) (PID \(p.pid), user \(p.user), command: \(p.command)) uses \(p.cpu) % CPU and \(ByteFormat.kb(Int64(p.rssKB))) of memory. Find out what it is and whether that is normal. Don't change anything yet — ask me first."
        } label: { Label("Investigate", systemImage: "sparkles") }
        Button { UIPasteboard.general.string = p.command } label: { Label("Copy Command", systemImage: "doc.on.doc") }
        Button { UIPasteboard.general.string = String(p.pid) } label: { Label("Copy PID", systemImage: "number") }
        if canEnd(p) {
            Divider()
            Button(role: .destructive) { ending = p } label: { Label("End Process…", systemImage: "xmark.circle") }
        }
    }

    private func canEnd(_ p: ProcessInfoRow) -> Bool { p.pid > 1 && !p.isKernelThread }

    private func end(_ p: ProcessInfoRow, force: Bool) {
        ending = nil
        guard let command = Processes.killCommand(pid: p.pid, force: force) else { return }
        Task {
            if p.user == snapshot?.me {
                do {
                    let conn = try await connections.connection(for: server)
                    let r = try await conn.run(command, timeout: .seconds(20))
                    if r.exitCode == 0 {
                        notice = r.stdout.contains("@@killed")
                            ? String(localized: "\(p.name) didn't quit in time and was forced to.")
                            : String(localized: "\(p.name) ended.")
                        error = nil
                    } else {
                        error = Processes.killMessage(r.stderr)
                    }
                } catch {
                    self.error = error.localizedDescription
                }
            } else {
                if await root.run(command, on: server) {
                    notice = String(localized: "\(p.name) ended.")
                    error = nil
                } else if case .failed(let m) = root.phase {
                    error = m
                } else if case .finished = root.phase {
                    error = Processes.killMessage(root.lines.joined(separator: "\n"))
                }
            }
            await load()
        }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(Processes.command, timeout: .seconds(30))
            guard let s = Processes.parse(r.stdout) else {
                throw ToolError.failed(String(localized: "This server doesn't offer /proc — the process list works on Linux servers."))
            }
            snapshot = s
            if error != nil && notice == nil { error = nil }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ProcessRow: View {
    let process: ProcessInfoRow
    let mine: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(process.name).font(.body.weight(.medium)).lineLimit(1)
                    if !mine && !process.user.isEmpty {
                        Text(process.user).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(process.command).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(process.cpu.formatted(.number.precision(.fractionLength(process.cpu < 10 ? 1 : 0))) + " %")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(process.cpu >= 80 ? .red : process.cpu >= 20 ? .orange : .primary)
                Text(process.rssKB > 0 ? ByteFormat.kb(Int64(process.rssKB)) : "–").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("process.\(process.pid)")
    }
}
