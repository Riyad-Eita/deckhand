import DeckhandCore
import SwiftUI

/// Crash and hang reports iOS handed to Deckhand (MetricKit). They stay here until you share one.
struct CrashReportsView: View {
    @State private var reporter = CrashReporter.shared
    @State private var confirmDelete = false

    var body: some View {
        List {
            if reporter.reports.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No reports", systemImage: "checkmark.seal").font(.headline)
                        Text("When Deckhand crashes or hangs, iOS hands a report to the app within a day. It shows up here, and only you decide whether to share it.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(reporter.reports) { r in
                        NavigationLink { CrashReportDetail(report: r) } label: { row(r) }
                            .accessibilityIdentifier("crash.report.\(r.kind.rawValue)")
                    }
                } footer: {
                    Text("Reports come from iOS (MetricKit) and stay on this iPhone. No crash service, no tracking.")
                }
                Section {
                    Button("Delete all reports", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle("Crash reports")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reporter.load() }
        .confirmationDialog("Delete all reports?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { reporter.deleteAll() }
        }
    }

    private func row(_ r: CrashReports.Report) -> some View {
        HStack(spacing: 12) {
            Image(systemName: r.kind == .crash ? "exclamationmark.octagon" : r.kind == .hang ? "hourglass" : "gauge.with.dots.needle.67percent")
                .foregroundStyle(r.kind == .crash ? .red : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.kind.title).font(.body.weight(.medium))
                Text(r.headline).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if let d = r.date {
                    Text("\(d.formatted(date: .abbreviated, time: .shortened)) · \(r.appVersion)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct CrashReportDetail: View {
    let report: CrashReports.Report
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Text(report.headline).font(.headline.monospaced()).accessibilityIdentifier("crash.headline")
                Text(report.explanation).font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("App", value: report.appVersion)
                LabeledContent("iOS", value: report.osVersion)
                LabeledContent("Device", value: report.device)
                if let d = report.date { LabeledContent("When", value: d.formatted(date: .abbreviated, time: .shortened)) }
            }
            if !report.frames.isEmpty {
                Section {
                    ForEach(Array(report.frames.enumerated()), id: \.offset) { i, f in
                        Text("\(i)  \(f)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                } header: {
                    Text("Where it happened")
                } footer: {
                    Text("Addresses inside the app; the developer turns them into function names with the build's symbols.")
                }
            }
            Section {
                Button {
                    var c = URLComponents(string: "https://github.com/Riyad-Eita/deckhand/issues/new")!
                    c.queryItems = [URLQueryItem(name: "title", value: "\(report.kind.title): \(report.headline)"),
                                    URLQueryItem(name: "body", value: CrashReports.issueBody(report))]
                    if let url = c.url { openURL(url) }
                } label: { Label("Report on GitHub", systemImage: "arrow.up.forward.square") }
                    .accessibilityIdentifier("crash.github")
                if let file = CrashReporter.shared.file(for: report) {
                    ShareLink(item: file) { Label("Share the full report", systemImage: "square.and.arrow.up") }
                }
            } footer: {
                Text("GitHub opens with the summary above filled in — you see everything before you send it. The full report holds the same plus memory addresses; it has no personal data.")
            }
        }
        .navigationTitle(report.kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
