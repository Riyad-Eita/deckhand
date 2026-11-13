import CryptoKit
import DeckhandCore
import Foundation
import MetricKit
import Observation

/// Receives MetricKit's crash, hang and resource reports (delivered by iOS at most once a day) and keeps them on this
/// iPhone. Nothing is sent anywhere; the user can share a report from Settings if they want to.
@MainActor
@Observable
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()
    static let keep = 30

    private(set) var reports: [CrashReports.Report] = []

    static var folder: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start() {
        MXMetricManager.shared.add(self)
        // Payloads delivered while the app wasn't listening.
        save(MXMetricManager.shared.pastDiagnosticPayloads.map { $0.jsonRepresentation() })
        load()
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let data = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor in self.save(data); self.load() }
    }

    func save(_ payloads: [Data]) {
        for data in payloads {
            // The same payload can arrive twice (past payloads + delivery); name files by content.
            let name = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
            let url = Self.folder.appending(path: "\(name).json")
            if !FileManager.default.fileExists(atPath: url.path()) { try? data.write(to: url, options: [.atomic, .completeFileProtection]) }
        }
        prune()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        reports = files.filter { $0.pathExtension == "json" }.flatMap { url -> [CrashReports.Report] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? nil
            return CrashReports.parse(data, fileID: url.deletingPathExtension().lastPathComponent).map { r in
                var r = r; if r.date == nil { r.date = created }; return r
            }
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// The raw MetricKit file a report came from, for sharing.
    func file(for report: CrashReports.Report) -> URL? {
        let name = report.id.components(separatedBy: "-").first ?? ""
        let url = Self.folder.appending(path: "\(name).json")
        return FileManager.default.fileExists(atPath: url.path()) ? url : nil
    }

    func deleteAll() {
        for url in (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
        reports = []
    }

    private func prune() {
        func created(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? nil) ?? .distantPast }
        let files = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { created($0) > created($1) }
        for url in files.dropFirst(Self.keep) { try? FileManager.default.removeItem(at: url) }
    }
}
