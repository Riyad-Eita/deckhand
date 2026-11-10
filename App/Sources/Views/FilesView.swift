import DeckhandCore
import SwiftData
import SwiftUI

/// Browse the files on a server: folders first, sort, hidden files, rename, delete, new folder,
/// and hand a path to the agent or the terminal.
struct FilesView: View {
    let server: Server
    /// nil: start in the server's working folder.
    var path: String?
    var runInTerminal: (String) -> Void = { _ in }

    @Environment(Connections.self) private var connections
    @AppStorage("files.sort") private var sort: FileSort = .name
    @AppStorage("files.showHidden") private var showHidden = false
    @State private var folder: RemoteFolder?
    @State private var error: String?
    @State private var loading = true
    @State private var query = ""

    @State private var renaming: RemoteFile?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var deleting: RemoteFile?
    @State private var task: FileTask?

    private var entries: [RemoteFile] {
        let all = RemoteFiles.sorted(folder?.entries ?? [], by: sort, showHidden: showHidden || query.hasPrefix("."))
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red).font(.footnote)
                    .accessibilityIdentifier("files.error")
            }
            if let folder {
                Section {
                    ForEach(entries) { file in
                        row(file, in: folder)
                    }
                    if entries.isEmpty {
                        Text(query.isEmpty ? "This folder is empty." : "Nothing matches.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(folder.path).font(Theme.monoSmall).textCase(nil).lineLimit(1).truncationMode(.head)
                        if !folder.writable {
                            Text("read-only").font(.caption2.weight(.semibold)).textCase(nil)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                } footer: {
                    if folder.truncated {
                        Text("Showing the first \(RemoteFiles.limit) entries.")
                    } else if !showHidden, case let hidden = folder.entries.filter(\.isHidden).count, hidden > 0 {
                        Text("\(hidden) hidden")
                    }
                }
            }
        }
        .overlay { if loading && folder == nil { ProgressView() } }
        .searchable(text: $query, prompt: "Filter")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: $sort) {
                        Label("Name", systemImage: "textformat").tag(FileSort.name)
                        Label("Date Modified", systemImage: "clock").tag(FileSort.modified)
                        Label("Size", systemImage: "arrow.up.arrow.down").tag(FileSort.size)
                    }
                    Toggle(isOn: $showHidden) { Label("Show Hidden Files", systemImage: "eye") }
                    if let folder {
                        Divider()
                        Button { newName = ""; creatingFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                            .disabled(!folder.writable)
                        Button { task = FileTask(directory: folder.path, draft: "") } label: {
                            Label("New Task Here", systemImage: "sparkles")
                        }
                        Button { runInTerminal("cd \(ShellQuote.quote(folder.path))") } label: {
                            Label("Open in Terminal", systemImage: "terminal")
                        }
                        Button { UIPasteboard.general.string = folder.path } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Folder Actions")
                .accessibilityIdentifier("files.menu")
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let f = renaming { change { try await RemoteFiles.rename(in: $1, from: f.name, to: newName, shell: $0) } } }
        }
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Create") { change { try await RemoteFiles.makeFolder(in: $1, name: newName, shell: $0) } }
        }
        .confirmationDialog(
            deleting.map { String(localized: "Delete “\($0.name)”?") } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleting { change { try await RemoteFiles.delete(DirectoryListing.join($1, f.name), shell: $0) } }
            }
        } message: {
            if let f = deleting {
                Text(f.opensAsFolder && f.kind == .folder
                     ? "The folder and everything in it is deleted on the server. This can't be undone."
                     : "It is deleted on the server. This can't be undone.")
            }
        }
        .fileTask($task, server: server)
        .task { await load() }
        .refreshable { await load() }
    }

    private var title: String {
        guard let p = folder?.path ?? path else { return String(localized: "Files") }
        return p == "/" ? "/" : (p as NSString).lastPathComponent
    }

    @ViewBuilder
    private func row(_ file: RemoteFile, in folder: RemoteFolder) -> some View {
        let full = DirectoryListing.join(folder.path, file.name)
        Group {
            if file.opensAsFolder {
                NavigationLink {
                    FilesView(server: server, path: full, runInTerminal: runInTerminal)
                } label: { FileRow(file: file) }
            } else if file.kind == .file {
                NavigationLink {
                    FileViewer(server: server, path: full, size: file.size)
                } label: { FileRow(file: file) }
            } else {
                FileRow(file: file)
            }
        }
        .contextMenu {
            if file.opensAsFolder {
                Button { task = FileTask(directory: full, draft: "") } label: { Label("New Task Here", systemImage: "sparkles") }
                Button { runInTerminal("cd \(ShellQuote.quote(full))") } label: { Label("Open in Terminal", systemImage: "terminal") }
            } else {
                Button { task = FileTask(directory: folder.path, draft: String(localized: "Have a look at `\(file.name)`: ")) } label: {
                    Label("Ask the Agent", systemImage: "sparkles")
                }
                Button { runInTerminal("cd \(ShellQuote.quote(folder.path)) && ls -la -- \(ShellQuote.quote(file.name))") } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
            }
            Button { UIPasteboard.general.string = full } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            if folder.writable {
                Divider()
                Button { newName = file.name; renaming = file } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { deleting = file } label: { Label("Delete", systemImage: "trash") }
                    .disabled(RemoteFiles.isProtected(full))
            }
        }
        .swipeActions(edge: .trailing) {
            if folder.writable && !RemoteFiles.isProtected(full) {
                // Not role: .destructive — the row stays until the user confirms (see the list crash lesson).
                Button { deleting = file } label: { Label("Delete", systemImage: "trash") }.tint(.red)
                Button { newName = file.name; renaming = file } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
            }
        }
    }

    /// Runs a change in this folder, then reloads. Errors show above the list.
    private func change(_ body: @escaping (any RemoteShell, String) async throws -> Void) {
        guard let dir = folder?.path else { return }
        Task {
            do {
                let conn = try await connections.connection(for: server)
                try await body(conn, dir)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            renaming = nil
            deleting = nil
            await load(keepError: true)
        }
    }

    private func load(keepError: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            let conn = try await connections.connection(for: server)
            folder = try await RemoteFiles.list(path ?? server.workingDirectory, shell: conn)
            if !keepError { error = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct FileRow: View {
    let file: RemoteFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(file.opensAsFolder ? Theme.accent : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name.replacingOccurrences(of: "\n", with: "␤"))
                    .font(.body)
                    .foregroundStyle(file.isHidden ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("file.\(file.name)")
    }

    private var symbol: String {
        switch file.kind {
        case .folder: "folder.fill"
        case .link: file.opensAsFolder ? "folder.badge.questionmark" : "link"
        case .other: "questionmark.square.dashed"
        case .file: FileRow.symbol(for: file.name)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let target = file.linkTarget { parts.append("→ \(target)") }
        if file.kind == .file { parts.append(file.size.formatted(.byteCount(style: .file))) }
        parts.append(file.modified.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "rb", "php", "java", "kt", "c", "h", "cpp", "sh", "css", "html":
            "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "ini", "conf", "env", "xml", "plist": "gearshape"
        case "md", "txt", "log", "csv": "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": "photo"
        case "zip", "gz", "tgz", "tar", "xz", "bz2", "7z": "doc.zipper"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }
}

/// Shows a text file (first 512 KB) with line numbers.
struct FileViewer: View {
    let server: Server
    let path: String
    let size: Int64

    static let maxBytes = 512 * 1024
    @Environment(Connections.self) private var connections
    @State private var lines: [Substring] = []
    @State private var binary = false
    @State private var error: String?
    @State private var loading = true
    @State private var task: FileTask?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Can't open the file", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if binary {
                ContentUnavailableView(
                    "Not a text file", systemImage: "doc",
                    description: Text("\(size.formatted(.byteCount(style: .file))) — open it in the terminal or ask the agent about it."))
            } else if loading {
                ProgressView()
            } else {
                ScrollView([.vertical, .horizontal]) {
                    let width = String(lines.count).count
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(String(i + 1).leftPadded(to: width)).foregroundStyle(.tertiary)
                                Text(line.isEmpty ? " " : String(line)).textSelection(.enabled)
                            }
                            .font(Theme.monoSmall)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        if size > Int64(Self.maxBytes) {
                            Text("Showing the first \(Int64(Self.maxBytes).formatted(.byteCount(style: .file))) of \(size.formatted(.byteCount(style: .file))).")
                                .font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        task = FileTask(directory: DirectoryListing.parent(of: path), draft: String(localized: "Have a look at `\((path as NSString).lastPathComponent)`: "))
                    } label: { Label("Ask the Agent", systemImage: "sparkles") }
                    Button { UIPasteboard.general.string = path } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                    if !binary && !lines.isEmpty {
                        Button { UIPasteboard.general.string = lines.joined(separator: "\n") } label: { Label("Copy Text", systemImage: "doc.plaintext") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("File Actions")
            }
        }
        .fileTask($task, server: server)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run("head -c \(Self.maxBytes) -- \(ShellQuote.quote(path))", timeout: .seconds(30))
            guard r.exitCode == 0 else { throw ToolError.failed(r.stderr.isEmpty ? "Can't read \(path)" : r.stderr) }
            if r.stdout.contains("\0") || r.stdout.contains("\u{FFFD}") { binary = true; return }
            lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true { lines.removeLast() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}

/// A task to start from the file browser: which folder it works in and what to put in the composer.
struct FileTask: Identifiable, Equatable {
    let id = UUID()
    let directory: String
    let draft: String
}

/// Pick an engine, then open a new task in the folder with the draft in the composer (not sent).
private struct FileTaskModifier: ViewModifier {
    @Binding var task: FileTask?
    let server: Server
    @Environment(\.modelContext) private var context
    @State private var thread: ChatThread?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "New task with",
                isPresented: Binding(get: { task != nil }, set: { if !$0 { task = nil } }),
                titleVisibility: .visible
            ) {
                ForEach([Engine.claudeCode, .codex, .ownKey]) { engine in
                    Button(engine.title) { start(engine) }
                }
            } message: {
                if let task { Text("Works in \(task.directory)") }
            }
            .navigationDestination(item: $thread) { AgentChatView(thread: $0, server: server) }
    }

    private func start(_ engine: Engine) {
        guard let task else { return }
        let t = ChatThread(server: server, workingDirectory: task.directory, engine: engine)
        context.insert(t)
        if !task.draft.isEmpty { PendingPrompt.setDraft(task.draft, for: t.id) }
        var recents = server.recentDirectories.filter { $0 != task.directory }
        recents.insert(task.directory, at: 0)
        server.recentDirectories = Array(recents.prefix(6))
        self.task = nil
        thread = t
    }
}

extension View {
    func fileTask(_ task: Binding<FileTask?>, server: Server) -> some View {
        modifier(FileTaskModifier(task: task, server: server))
    }
}
