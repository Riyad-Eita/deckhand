import DeckhandCore
import SwiftUI

/// Health of one server at a glance; refreshes every few seconds while visible.
struct ServerDashboardView: View {
    let server: Server
    /// Hands a prompt to the agent ("Investigate").
    var investigate: (String) -> Void = { _ in }
    /// Opens the terminal with a command (e.g. something that needs a sudo password).
    var runInTerminal: (String) -> Void = { _ in }
    @Environment(Connections.self) private var connections
    @State private var stats: ServerStats?
    @State private var error: String?
    @State private var updated: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let stats {
                    if !stats.warnings.isEmpty {
                        WarningsCard(warnings: stats.warnings) { warning in
                            investigate("On this server: \(warning). Find out what causes it and suggest safe fixes, biggest win first. Don't change anything yet — ask me before you do.")
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        MetricCard(title: "CPU", value: percent(stats.cpu), detail: "\(stats.cores) cores", fraction: stats.cpu)
                        MetricCard(
                            title: "Memory", value: percent(stats.memUsedFraction),
                            detail: "\(ByteFormat.kb(stats.memTotalKB - stats.memAvailableKB)) of \(ByteFormat.kb(stats.memTotalKB))",
                            fraction: stats.memUsedFraction)
                        MetricCard(
                            title: "Load", value: String(format: "%.2f", stats.load.0),
                            detail: String(format: "5m %.2f · 15m %.2f", stats.load.1, stats.load.2),
                            fraction: stats.cores > 0 ? min(1, stats.load.0 / Double(stats.cores)) : 0)
                        MetricCard(title: "Uptime", value: ByteFormat.duration(stats.uptime), detail: "since last boot", fraction: nil)
                    }
                    VStack(spacing: 0) {
                        NavigationLink {
                            ServicesView(server: server, runInTerminal: runInTerminal, investigate: investigate)
                        } label: {
                            ManageRow(title: "Services", subtitle: "systemd: status, restart, logs", symbol: "gearshape.2")
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Disks").font(.headline)
                        ForEach(stats.disks) { disk in DiskRow(disk: disk) }
                    }
                    .padding(16)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline))
                    if let updated {
                        Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                    }
                } else if let error {
                    ContentUnavailableView("Can't read this server", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("Reading the server…").frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .refreshable { await refresh() }
    }

    private func percent(_ f: Double) -> String { "\(Int((f * 100).rounded())) %" }

    private func refresh() async {
        do {
            let conn = try await connections.connection(for: server)
            let r = try await conn.run(ServerStats.probeCommand, timeout: .seconds(15))
            guard let s = ServerStats.parse(r.stdout) else {
                throw ToolError.failed("This server doesn't look like Linux (no /proc).")
            }
            stats = s
            error = nil
            updated = Date()
        } catch {
            if stats == nil { self.error = error.localizedDescription }
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
            if let fraction { UsageBar(fraction: fraction) }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline))
        .accessibilityElement(children: .combine)
    }
}

private struct UsageBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
    private var color: Color { fraction >= 0.9 ? .red : fraction >= 0.8 ? .orange : Theme.accent }
}

private struct DiskRow: View {
    let disk: ServerStats.Disk
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(disk.mount).font(Theme.mono)
                Spacer()
                Text("\(ByteFormat.kb(disk.availableKB)) free of \(ByteFormat.kb(disk.usedKB + disk.availableKB))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            UsageBar(fraction: disk.usedFraction)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WarningsCard: View {
    let warnings: [String]
    let investigate: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(warnings, id: \.self) { w in
                HStack {
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Investigate") { investigate(w) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

struct ManageRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32).background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .contentShape(Rectangle())
    }
}
