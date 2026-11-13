import DeckhandCore
import SwiftUI

/// Log sources on one server: the journal and readable log files, newest first.
struct LogsView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var sources: [LogSource] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            Section {
                ForEach(sources) { source in
                    NavigationLink {
                        LogViewer(server: server, source: source)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(source)).foregroundStyle(Theme.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title).font(.body.weight(.medium))
                                Text(source.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            } footer: {
                Text("Files you can read under /var/log and in your home folder. " + Logs.journalHint)
            }
        }
        .overlay { if loading && sources.isEmpty { ProgressView() } }
        .navigationTitle("Logs")
        .task { await load() }
        .refreshable { await load() }
    }

    private func icon(_ s: LogSource) -> String {
        if case .journal = s { return "list.bullet.rectangle" }
        return "doc.text"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let conn = try await connections.connection(for: server)
            sources = Logs.parseSources(try await conn.run(Logs.discoverCommand, timeout: .seconds(40)).stdout)
            error = sources.isEmpty ? "No readable logs found." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One log: colored by severity, filter, search, follow live, explain with an agent.
struct LogViewer: View {
    let server: Server
    let source: LogSource

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", problems = "Problems", errors = "Errors"
        var id: String { rawValue }
    }

    @Environment(Connections.self) private var connections
    @State private var lines: [LogLine] = []
    @State private var nextID = 0
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var following = false
    @State private var followTask: Task<Void, Never>?
    @State private var loading = true
    @State private var investigatePrompt: String?
    @State private var explaining: String?

    private var shown: [LogLine] {
        lines.filter { line in
            switch filter {
            case .all: true
            case .problems: line.level >= .warning
            case .errors: line.level == .error
            }
        }
        .filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { line in
                        Text(line.text)
                            .font(Theme.monoSmall)
                            .foregroundStyle(color(line.level))
                            .padding(.horizontal, 4)
                            .background(line.level == .error ? Color.red.opacity(0.08) : .clear)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onChange(of: lines.count) { if following { proxy.scrollTo("end", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .overlay {
            if loading && lines.isEmpty { ProgressView() }
            else if !loading && shown.isEmpty { ContentUnavailableView("No lines", systemImage: "line.3.horizontal.decrease.circle") }
        }
        .searchable(text: $query, prompt: "Search")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                Button {
                    explaining = shown.suffix(120).map(\.text).joined(separator: "\n")
                } label: {
                    Label("Explain", systemImage: "sparkle.magnifyingglass")
                }
                .accessibilityIdentifier("logs.explain")
                .buttonStyle(.borderedProminent)
                .disabled(shown.isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
        .sheet(item: Binding(get: { explaining.map { ExplainText(text: $0) } }, set: { explaining = $0?.text })) { e in
            ExplainSheet(text: e.text, context: String(localized: "the log \(source.title)")) { _ in
                investigatePrompt = Logs.explainPrompt(source: source, lines: shown)
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { following ? stopFollowing() : startFollowing() } label: {
                    Label(following ? "Stop" : "Follow", systemImage: following ? "pause.circle.fill" : "dot.radiowaves.left.and.right")
                }
            }
        }
        .task { await load() }
        .onDisappear { stopFollowing() }
        .investigate(on: server, prompt: $investigatePrompt)
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .error: .red
        case .warning: .orange
        case .info: .primary
        }
    }

    private func append(_ text: String) {
        lines.append(LogLine(id: nextID, text: text))
        nextID += 1
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let conn = try? await connections.connection(for: server),
              let r = try? await conn.run(Logs.readCommand(source), timeout: .seconds(30)) else { return }
        lines = []
        for line in r.stdout.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty { append(String(line)) }
    }

    private func startFollowing() {
        following = true
        followTask = Task {
            guard let conn = try? await connections.connection(for: server) else { following = false; return }
            while !Task.isCancelled && following {
                do {
                    for try await line in conn.streamLines(Logs.followCommand(source)) { append(line) }
                } catch {
                    break
                }
            }
            following = false
        }
    }

    private func stopFollowing() {
        following = false
        followTask?.cancel()
        followTask = nil
    }
}
