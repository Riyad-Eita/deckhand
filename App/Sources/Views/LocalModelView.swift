import DeckhandCore
import DeckhandSSH
import SwiftUI

/// Your own model on your own server: hardware check, Ollama install, a model that fits, its speed and memory,
/// and one tap to use it in chats (reached through the SSH connection, never exposed to the internet).
struct LocalModelView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var root = RootRunner()
    @State private var status: OllamaSetup.Status?
    @State private var chosen = ""
    @State private var busy: String?
    @State private var pull: OllamaSetup.PullProgress?
    @State private var benchmarks: [String: OllamaSetup.Benchmark] = [:]
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let s = status {
                hardware(s)
                let choices = OllamaSetup.choices(for: s)
                if !s.running {
                    installSection(s, choices)
                } else {
                    modelsSection(s)
                    addSection(s, choices)
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView("Checking the hardware…"); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Your own AI model")
        .navigationBarTitleDisplayMode(.inline)
        .sudoPassword(root, server: server)
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - Sections

    private func hardware(_ s: OllamaSetup.Status) -> some View {
        Section {
            LabeledContent("Processor", value: String(localized: "\(s.cpus) cores · \(s.arch)"))
            LabeledContent("Memory", value: String(localized: "\(gb(mb: s.memoryMB)) · \(gb(mb: s.availableMB)) free"))
            LabeledContent("Graphics", value: s.gpu.map { "\($0) · \(gb(mb: s.gpuMemoryMB))" } ?? String(localized: "None — runs on the processor"))
            LabeledContent("Disk free", value: gb(mb: s.diskFreeMB))
        } header: {
            Text("This server")
        }
        .accessibilityIdentifier("localModel.hardware")
    }

    @ViewBuilder
    private func installSection(_ s: OllamaSetup.Status, _ choices: (fitting: [OllamaSetup.Choice], suggested: OllamaSetup.Choice?)) -> some View {
        if choices.fitting.isEmpty {
            Section {
                Text("This server has too little free memory or disk for a local model. The smallest one needs about 1.1 GB of free memory and 1.5 GB of disk.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(choices.fitting) { c in choiceRow(c, suggested: c == choices.suggested) }
                Button {
                    Task { await installAndPull(chosen.isEmpty ? choices.suggested?.name ?? "" : chosen) }
                } label: {
                    HStack {
                        Text(s.installed ? "Start Ollama and download" : "Install Ollama and download").font(.headline)
                        Spacer()
                        if busy != nil { ProgressView() }
                    }
                }
                .disabled(busy != nil)
                .accessibilityIdentifier("localModel.install")
                progress
            } header: {
                Text("Pick a model")
            } footer: {
                Text("Ollama is installed with its official script and listens only on the server itself; Deckhand reaches it through your SSH connection. Your prompts never leave your server.")
            }
        }
    }

    private func modelsSection(_ s: OllamaSetup.Status) -> some View {
        Section {
            if s.models.isEmpty {
                Text("Ollama runs, but no model is downloaded yet.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(s.models) { m in
                ModelRow(model: m, benchmark: benchmarks[m.name], loaded: s.loaded.first { $0.name == m.name },
                         inUse: inUse(m.name), measuring: busy == "measure:\(m.name)")
                    .swipeActions {
                        Button("Delete", role: .destructive) { Task { await delete(m.name) } }
                        Button("Measure") { Task { await measure(m.name) } }.tint(.gray)
                    }
                    .contextMenu {
                        Button { use(m.name) } label: { Label("Use for chats", systemImage: "bubble.left.and.text.bubble.right") }
                        Button { Task { await measure(m.name) } } label: { Label("Measure speed", systemImage: "speedometer") }
                        Button(role: .destructive) { Task { await delete(m.name) } } label: { Label("Delete", systemImage: "trash") }
                    }
                if !inUse(m.name) {
                    Button { use(m.name) } label: { Label(String(localized: "Use \(m.name) for chats"), systemImage: "bubble.left.and.text.bubble.right") }
                        .accessibilityIdentifier("localModel.use.\(m.name)")
                }
            }
        } header: {
            Text("Models · Ollama \(s.version ?? "")")
        } footer: {
            Text("Chats with a model from this server go through your SSH connection; the server has to be reachable while you chat.")
        }
    }

    @ViewBuilder
    private func addSection(_ s: OllamaSetup.Status, _ choices: (fitting: [OllamaSetup.Choice], suggested: OllamaSetup.Choice?)) -> some View {
        let missing = choices.fitting.filter { c in !s.models.contains { $0.name == c.name } }
        if !missing.isEmpty {
            Section("Add a model") {
                ForEach(missing) { c in choiceRow(c, suggested: c == choices.suggested) }
                Button {
                    Task { await download(chosen.isEmpty ? missing.last?.name ?? "" : chosen) }
                } label: {
                    HStack { Text("Download").font(.headline); Spacer(); if busy != nil { ProgressView() } }
                }
                .disabled(busy != nil || (chosen.isEmpty && missing.isEmpty))
                .accessibilityIdentifier("localModel.download")
                progress
            }
        }
    }

    private func choiceRow(_ c: OllamaSetup.Choice, suggested: Bool) -> some View {
        Button { chosen = c.name } label: {
            HStack(alignment: .top, spacing: 10) {
                let on = chosen == c.name || (chosen.isEmpty && suggested && status?.running != true)
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.title).font(.body.weight(.medium))
                        if suggested { Text("Suggested").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent) }
                        Spacer()
                        Text(String(format: "%.1f GB", c.sizeGB)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(LocalizedStringKey(c.note)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("localModel.choice.\(c.name)")
    }

    @ViewBuilder
    private var progress: some View {
        if let busy, busy.hasPrefix("pull") || busy == "install" {
            VStack(alignment: .leading, spacing: 6) {
                if let f = pull?.fraction { ProgressView(value: f) } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                Text(busy == "install" ? String(localized: "Installing Ollama…") : (pull?.status ?? String(localized: "Starting the download…")))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: - Actions

    private func inUse(_ model: String) -> Bool {
        settings.providerKind == .custom && settings.model == model
            && URL(string: settings.baseURL).flatMap(ServerModelURL.parse)?.serverID == server.id
    }

    private func use(_ model: String) {
        settings.providerKind = .custom
        settings.baseURL = ServerModelURL.make(serverID: server.id).absoluteString
        settings.model = model
    }

    private func installAndPull(_ model: String) async {
        guard !model.isEmpty else { return }
        error = nil
        busy = "install"
        let ok = await root.run(OllamaSetup.installScript, on: server)
        busy = nil
        guard ok else {
            if root.phase != .idle { error = root.lines.last(where: { !$0.hasPrefix("@@") }) ?? String(localized: "Ollama couldn't be installed.") }
            await load(); return
        }
        await load()
        await download(model)
    }

    private func download(_ model: String) async {
        guard !model.isEmpty else { return }
        error = nil; pull = nil
        busy = "pull:\(model)"
        do {
            let conn = try await connections.connection(for: server)
            let channel = try await conn.openChannel(OllamaSetup.pullCommand(model))
            defer { channel.close() }
            for try await line in channel.lines {
                if line == "@@done" { break }
                if let p = OllamaSetup.parsePullLine(line) {
                    if let e = p.error { throw ToolError.failed(e) }
                    pull = p
                }
            }
        } catch { self.error = error.localizedDescription }
        busy = nil; pull = nil
        chosen = ""
        await load()
        if error == nil { await measure(model) }
        // The first model downloaded becomes the chat model if none from a server is set yet.
        if error == nil, URL(string: settings.baseURL).flatMap(ServerModelURL.parse) == nil || settings.providerKind != .custom,
           !settings.isConfigured { use(model) }
    }

    private func measure(_ model: String) async {
        busy = "measure:\(model)"
        defer { busy = nil }
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(OllamaSetup.benchmarkCommand(model), timeout: .seconds(620)).stdout
            if let b = OllamaSetup.parseBenchmark(out, model: model) { benchmarks[model] = b; error = nil }
            else { error = OllamaSetup.benchmarkError(out) ?? String(localized: "The model didn't answer.") }
        } catch { self.error = error.localizedDescription }
        await load()
    }

    private func delete(_ model: String) async {
        do {
            let conn = try await connections.connection(for: server)
            _ = try await conn.run(OllamaSetup.deleteCommand(model), timeout: .seconds(60))
            benchmarks[model] = nil
        } catch { self.error = error.localizedDescription }
        await load()
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            status = OllamaSetup.parse(try await conn.run(OllamaSetup.statusCommand, timeout: .seconds(30)).stdout)
        } catch { self.error = error.localizedDescription }
    }

    private func gb(mb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mb) * 1_048_576, countStyle: .memory)
    }
}

private struct ModelRow: View {
    let model: OllamaSetup.Model
    let benchmark: OllamaSetup.Benchmark?
    let loaded: OllamaSetup.Loaded?
    let inUse: Bool
    let measuring: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.name).font(.body.weight(.medium).monospaced())
                if inUse {
                    Label("In use", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
                Spacer()
                if measuring { ProgressView() }
            }
            HStack(spacing: 12) {
                if !model.parameters.isEmpty { stat("cube", model.parameters) }
                stat("internaldrive", ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
            }
            if let b = benchmark {
                HStack(spacing: 12) {
                    stat("speedometer", String(localized: "\(Int(b.tokensPerSecond.rounded())) tokens/s"))
                        .accessibilityIdentifier("localModel.speed")
                    if b.memoryBytes > 0 { stat("memorychip", ByteCountFormatter.string(fromByteCount: b.memoryBytes, countStyle: .memory)) }
                    stat(b.onGPU ? "cpu.fill" : "cpu", b.onGPU ? String(localized: "GPU") : String(localized: "Processor"))
                }
                .foregroundStyle(.primary)
                if !b.sample.isEmpty {
                    Text(b.sample).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            } else if let loaded {
                stat("memorychip", String(localized: "In memory: \(ByteCountFormatter.string(fromByteCount: loaded.sizeBytes, countStyle: .memory))"))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localModel.model.\(model.name)")
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption.monospacedDigit()).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
    }
}
