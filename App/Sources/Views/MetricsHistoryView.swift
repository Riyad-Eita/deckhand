import Charts
import DeckhandCore
import SwiftUI

/// Seven days of CPU, memory, disk, network and load from the server's own sampler, with spikes marked.
struct MetricsHistoryView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var installed: Bool?
    @State private var samples: [MetricsHistory.Sample] = []
    @State private var metric: MetricsHistory.Metric = .cpu
    @State private var days = 1
    @State private var busy = false
    @State private var error: String?

    private var points: [MetricsHistory.Point] {
        MetricsHistory.series(samples, metric: metric, since: Date().addingTimeInterval(-Double(days) * 86_400))
    }

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if installed == false {
                Section {
                    Text("The server records CPU, memory, disk, network and load every five minutes and keeps seven days — so you see trends even when the app was closed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button { Task { await perform(MetricsHistory.installCommand) } } label: {
                        HStack { Text("Start recording").font(.headline); Spacer(); if busy { ProgressView() } }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("metrics.install")
                }
            } else if installed == true {
                Section {
                    Picker("Metric", selection: $metric) { ForEach(MetricsHistory.Metric.allCases) { Text(LocalizedStringKey($0.title)).tag($0) } }
                        .pickerStyle(.segmented)
                    Picker("Range", selection: $days) {
                        Text("24 hours").tag(1)
                        Text("7 days").tag(7)
                    }
                    .pickerStyle(.segmented)
                    if points.count < 2 {
                        Text("Collecting — the first points show up within ten minutes.").foregroundStyle(.secondary)
                            .accessibilityIdentifier("metrics.collecting")
                    } else {
                        chart.frame(height: 220).accessibilityIdentifier("metrics.chart")
                        if let s = MetricsHistory.summary(points) {
                            HStack {
                                stat("Average", value(s.average))
                                Spacer()
                                stat("Peak", value(s.peak) + " · " + s.peakAt.formatted(days > 1 ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.hour().minute()))
                            }
                        }
                        let spikes = points.filter(\.spike)
                        if !spikes.isEmpty {
                            Label(spikes.count == 1 ? String(localized: "An unusual spike \(spikes[0].date.formatted(.relative(presentation: .named)))")
                                  : String(localized: "\(spikes.count) unusual spikes, last \(spikes.last!.date.formatted(.relative(presentation: .named)))"),
                                  systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Button("Stop recording", role: .destructive) { Task { await perform(MetricsHistory.uninstallCommand) } }
                } footer: {
                    Text("Sampled by cron every 5 minutes; nothing leaves the server except when you open this screen.")
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private var chart: some View {
        Chart(points) { p in
            AreaMark(x: .value("Time", p.date), y: .value(metric.title, p.value))
                .foregroundStyle(Theme.accent.opacity(0.12))
            LineMark(x: .value("Time", p.date), y: .value(metric.title, p.value))
                .foregroundStyle(Theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            if p.spike {
                PointMark(x: .value("Time", p.date), y: .value(metric.title, p.value))
                    .foregroundStyle(.red).symbolSize(40)
            }
        }
        .chartYScale(domain: metric == .network || metric == .load ? .automatic(includesZero: true) : .automatic(includesZero: true))
        .chartYAxis { AxisMarks(position: .leading) }
    }

    private func value(_ v: Double) -> String {
        switch metric {
        case .load: String(format: "%.2f", v)
        case .network: v >= 1024 ? String(format: "%.1f MB/s", v / 1024) : String(format: "%.0f KB/s", v)
        default: String(format: "%.0f %%", v)
        }
    }

    private func stat(_ title: LocalizedStringKey, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.callout.monospacedDigit().weight(.medium))
        }
    }

    private func perform(_ command: String) async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(command, timeout: .seconds(60)).stdout
            error = out.contains("@@nocron") ? String(localized: "This server has no cron, so nothing can be recorded in the background.") : nil
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            let r = MetricsHistory.parse(try await conn.run(MetricsHistory.readCommand(), timeout: .seconds(60)).stdout)
            installed = r.installed
            samples = r.samples
        } catch { self.error = error.localizedDescription }
    }
}
