import DeckhandCore
import SwiftUI

/// Reads a file on the server: syntax highlighting, line numbers, find in file, optional line wrapping.
/// Loads the first 512 KB; rows are lazy so long files scroll smoothly.
struct FileViewer: View {
    let server: Server
    let path: String
    let size: Int64

    static let maxBytes = 512 * 1024
    @Environment(Connections.self) private var connections
    @AppStorage("viewer.wrap") private var wrap = false
    @State private var lines: [Substring] = []
    @State private var tokens: [[SyntaxHighlighter.Token]] = []
    @State private var binary = false
    @State private var error: String?
    @State private var loading = true
    @State private var task: FileTask?
    @State private var query = ""
    @State private var matches: [TextSearch.Match] = []
    @State private var current = 0
    /// Characters in the longest line, for the width of the unwrapped view.
    @State private var longest = 0
    /// Logs: following new lines (`tail -F`).
    @State private var following = false
    @State private var follower: Task<Void, Never>?
    @State private var shareURL: URL?
    @State private var editing = false
    @State private var preparingShare = false

    private var isLog: Bool { FilePreview.kind(forFileName: name) == .log }

    /// Minified files and other very long lines are always wrapped.
    private var wrapping: Bool { wrap || longest > 1000 }

    private var name: String { (path as NSString).lastPathComponent }
    private var language: SyntaxHighlighter.Language? { SyntaxHighlighter.language(forFileName: name) }

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 14) { Text("Can't open the file").font(.title3.weight(.semibold)); ProblemView(message: error) }.frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if binary {
                ContentUnavailableView(
                    "Not a text file", systemImage: "doc",
                    description: Text("\(size.formatted(.byteCount(style: .file))) — open it in the terminal or ask the agent about it."))
            } else if loading {
                ProgressView()
            } else {
                code
            }
        }
        .navigationTitle(name)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find in file")
        .onChange(of: query) { _, q in
            matches = TextSearch.matches(in: lines, query: q)
            current = 0
        }
        .safeAreaInset(edge: .bottom) {
            if !query.isEmpty { searchBar }
        }
        .toolbar {
            if isLog && !binary && error == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { following ? stopFollowing() : startFollowing() } label: {
                        Label(following ? String(localized: "Stop following") : String(localized: "Follow"),
                              systemImage: following ? "pause.circle.fill" : "play.circle")
                    }
                    .accessibilityIdentifier("viewer.follow")
                }
            }
            if !binary && error == nil && !loading && !following && size <= Int64(FileEditing.maxBytes) {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        .accessibilityIdentifier("viewer.edit")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle(isOn: $wrap) { Label("Wrap Lines", systemImage: "text.word.spacing") }
                    Divider()
                    Button {
                        task = FileTask(directory: DirectoryListing.parent(of: path), draft: String(localized: "Have a look at `\(name)`: "))
                    } label: { Label("Ask the Agent", systemImage: "sparkles") }
                    Button { Task { await prepareShare() } } label: { Label("Share File", systemImage: "square.and.arrow.up") }
                        .disabled(preparingShare)
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
        .onDisappear { follower?.cancel() }
        .fullScreenCover(isPresented: $editing) {
            FileEditorView(server: server, path: path) { Task { await load() } }
        }
        .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { shareURL = $0?.url })) { item in
            ShareSheet(items: [item.url]).presentationDetents([.medium, .large])
        }
    }

    private var subtitle: String {
        guard !loading, !binary, error == nil else { return "" }
        let count = String(localized: "\(lines.count) lines")
        return [language?.name, count].compactMap { $0 }.joined(separator: " · ")
    }

    private var code: some View {
        ScrollViewReader { proxy in
            ScrollView(wrapping ? .vertical : [.vertical, .horizontal]) {
                let width = String(lines.count).count
                let focused = matches.indices.contains(current) ? matches[current] : nil
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { i in
                        CodeLine(
                            number: i + 1, width: width, text: lines[i],
                            tokens: tokens.indices.contains(i) ? tokens[i] : [],
                            hits: matches.isEmpty ? [] : hits(on: i), focused: focused?.line == i ? focused : nil,
                            wrap: wrapping)
                        .id(i)
                    }
                    if size > Int64(Self.maxBytes) {
                        Text("Showing the first \(Int64(Self.maxBytes).formatted(.byteCount(style: .file))) of \(size.formatted(.byteCount(style: .file))).")
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }
                // Every row as wide as the longest one, so rows wider than the screen keep their line numbers
                // (lazy rows would otherwise overflow centred).
                .frame(minWidth: wrapping ? nil : contentWidth(digits: width), alignment: .leading)
                .padding(.vertical, 10)
                .padding(.trailing, 12)
            }
            .onChange(of: current) { _, _ in jump(proxy) }
            .onChange(of: lines.count) { _, n in
                if following, n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            .onChange(of: matches) { _, _ in jump(proxy) }
        }
    }

    private func contentWidth(digits: Int) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        let char = ("0" as NSString).size(withAttributes: [.font: font]).width
        return 12 + CGFloat(digits) * char + 10 + CGFloat(longest + 1) * char
    }

    private var searchBar: some View {
        HStack(spacing: 14) {
            Text(matches.isEmpty ? String(localized: "No matches") : String(localized: "\(current + 1) of \(matches.count)"))
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("viewer.matches")
            Spacer()
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(matches.isEmpty).accessibilityLabel("Previous Match")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .disabled(matches.isEmpty).accessibilityLabel("Next Match")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func hits(on line: Int) -> [TextSearch.Match] {
        matches.filter { $0.line == line }
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        current = (current + delta + matches.count) % matches.count
    }

    private func jump(_ proxy: ScrollViewProxy) {
        guard matches.indices.contains(current) else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(matches[current].line, anchor: UnitPoint(x: 0, y: 0.4)) }
    }

    /// Shows the end of the log and then every new line as it's written.
    private func startFollowing() {
        following = true
        lines = []; tokens = []; matches = []; longest = 0
        follower = Task {
            do {
                let conn = try await connections.connection(for: server)
                let channel = try await conn.openChannel(FilePreview.followCommand(path))
                defer { channel.close() }
                for try await line in channel.lines {
                    let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
                    lines.append(Substring(clean))
                    longest = max(longest, clean.utf16.count)
                    if lines.count > 20_000 { lines.removeFirst(lines.count - 20_000) }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            following = false
        }
    }

    private func stopFollowing() {
        follower?.cancel()
        follower = nil
        following = false
    }

    private func prepareShare() async {
        preparingShare = true
        defer { preparingShare = false }
        do {
            let conn = try await connections.connection(for: server)
            let data = try await conn.download(path, maxBytes: Int(FilePreview.maxPreviewBytes))
            shareURL = try QuickLookFileView.temporaryFile(named: name, data: data)
        } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run("head -c \(Self.maxBytes) -- \(ShellQuote.quote(path))", timeout: .seconds(30))
            guard r.exitCode == 0 else { throw ToolError.failed(r.stderr.isEmpty ? "Can't read \(path)" : r.stderr) }
            if r.stdout.contains("\0") || r.stdout.contains("\u{FFFD}") { binary = true; return }
            var split = r.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            if split.last?.isEmpty == true { split.removeLast() }
            // Windows line endings: drop the \r so it doesn't show up.
            let clean = split.map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
            lines = clean
            longest = clean.reduce(0) { max($0, $1.utf16.count) }
            if let language {
                tokens = await Task.detached(priority: .userInitiated) {
                    SyntaxHighlighter.highlight(clean, language: language)
                }.value
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One line: number, coloured code, search hits.
private struct CodeLine: View {
    let number: Int
    let width: Int
    let text: Substring
    let tokens: [SyntaxHighlighter.Token]
    let hits: [TextSearch.Match]
    let focused: TextSearch.Match?
    let wrap: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(number).leftPadded(to: width))
                .foregroundStyle(.tertiary)
                .padding(.leading, 12)
            Text(attributed)
                .textSelection(.enabled)
                .fixedSize(horizontal: !wrap, vertical: true)
        }
        .font(Theme.monoSmall)
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        CodeColors.attributed(text.isEmpty ? " " : String(text), tokens: tokens, hits: hits, focused: focused)
    }
}

/// Colours for code, tuned for the light and dark backgrounds of the app.
enum CodeColors {
    static func color(_ kind: SyntaxHighlighter.Kind) -> UIColor {
        switch kind {
        case .keyword: dynamic(0xAD3DA4, 0xFF7AB2)
        case .string: dynamic(0xC41A16, 0xFC6A5D)
        case .comment: dynamic(0x6C7986, 0x7F8C98)
        case .number: dynamic(0x1C00CF, 0xD9C97C)
        case .type: dynamic(0x3D6FF2, 0x6E95FF)
        case .key: dynamic(0x0F68A0, 0x41A1C0)
        case .tag: dynamic(0x8A3FBF, 0xB281EB)
        case .plain: .label
        }
    }

    /// Colours tokens and search hits into an AttributedString.
    static func attributed(_ text: String, tokens: [SyntaxHighlighter.Token], hits: [TextSearch.Match] = [], focused: TextSearch.Match? = nil) -> AttributedString {
        let ns = NSMutableAttributedString(string: text)
        let length = ns.length
        for t in tokens where t.start + t.length <= length {
            ns.addAttribute(.foregroundColor, value: color(t.kind), range: NSRange(location: t.start, length: t.length))
        }
        for h in hits where h.start + h.length <= length {
            ns.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(h == focused ? 0.75 : 0.3),
                            range: NSRange(location: h.start, length: h.length))
        }
        return (try? AttributedString(ns, including: \.uiKit)) ?? AttributedString(text)
    }

    /// A whole block of code (e.g. from a chat reply) in one AttributedString.
    static func attributed(code: String, language: SyntaxHighlighter.Language?) -> AttributedString {
        guard let language else { return AttributedString(code) }
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let perLine = SyntaxHighlighter.highlight(lines, language: language)
        var tokens: [SyntaxHighlighter.Token] = []
        var offset = 0
        for (line, lineTokens) in zip(lines, perLine) {
            tokens += lineTokens.map { SyntaxHighlighter.Token(kind: $0.kind, start: $0.start + offset, length: $0.length) }
            offset += line.utf16.count + 1
        }
        return attributed(code, tokens: tokens)
    }

    private static func dynamic(_ light: Int, _ dark: Int) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
    }

    private static func rgb(_ v: Int) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension String {
    func leftPadded(to width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet for files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
