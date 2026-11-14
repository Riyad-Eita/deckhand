import DeckhandCore
import Foundation
import Observation

/// Saved commands in a JSON file in Application Support.
@MainActor
@Observable
final class SnippetStore {
    static let shared = SnippetStore()

    var snippets: [Snippet] = [] { didSet { save() } }
    private var loading = false

    private static var file: URL {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "snippets.json")
    }

    init() {
        loading = true
        if let data = try? Data(contentsOf: Self.file), let list = try? JSONDecoder().decode([Snippet].self, from: data) { snippets = list }
        loading = false
    }

    private func save() {
        guard !loading, let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: Self.file, options: [.atomic, .completeFileProtection])
    }

    func used(_ s: Snippet) {
        guard let i = snippets.firstIndex(where: { $0.id == s.id }) else { return }
        snippets[i].uses += 1
        snippets[i].lastUsed = Date()
    }

    func upsert(_ s: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == s.id }) { snippets[i] = s } else { snippets.append(s) }
    }
}
