import DeckhandCore
import QuickLook
import SwiftUI

/// Images and PDFs from the server, shown with Quick Look (zoom, pages, markup) and shareable. The file is fetched
/// over SFTP into a temporary folder that iOS clears.
struct QuickLookFileView: View {
    let server: Server
    let path: String
    let size: Int64
    @Environment(Connections.self) private var connections
    @State private var url: URL?
    @State private var error: String?

    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 14) { Text("Can't open the file").font(.title3.weight(.semibold)); ProblemView(message: error) }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if size > FilePreview.maxPreviewBytes {
                ContentUnavailableView("Too large to preview", systemImage: "doc",
                                       description: Text("\(size.formatted(.byteCount(style: .file))) — open it in the terminal or ask the agent about it."))
            } else if let url {
                QuickLookPreview(url: url).ignoresSafeArea(edges: .bottom)
                    .accessibilityIdentifier("preview.quicklook")
            } else {
                ProgressView(String(localized: "Loading \(size.formatted(.byteCount(style: .file)))…"))
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share")
                        .accessibilityIdentifier("preview.share")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard url == nil, size <= FilePreview.maxPreviewBytes else { return }
        do {
            let conn = try await connections.connection(for: server)
            let data = try await conn.download(path, maxBytes: Int(FilePreview.maxPreviewBytes))
            url = try Self.temporaryFile(named: name, data: data)
        } catch { self.error = error.localizedDescription }
    }

    /// A copy in the temporary folder, named like the original (Quick Look and sharing use the name).
    static func temporaryFile(named name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "previews/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name.isEmpty ? "file" : name)
        try data.write(to: url, options: .completeFileProtection)
        return url
    }
}

/// Quick Look embedded in a SwiftUI view.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
