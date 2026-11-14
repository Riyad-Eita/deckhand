import SwiftUI

/// The home-screen widget's faces. Neutral by default; color only means something is filling up.
enum ServerStatusStyle {
    static func color(_ level: ServerSnapshot.Level) -> Color {
        switch level {
        case .ok: .primary.opacity(0.75)
        case .warning: .orange
        case .critical: .red
        }
    }

    static func dot(_ level: ServerSnapshot.Level) -> Color {
        switch level {
        case .ok: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    static func percent(_ f: Double?) -> String {
        guard let f else { return "–" }
        return "\(Int((min(max(f, 0), 1) * 100).rounded())) %"
    }
}

/// One server: name, three bars, when it was fetched.
struct ServerStatusSmallView: View {
    let snapshot: ServerSnapshot?
    var now: Date = .now

    var body: some View {
        if let s = snapshot {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(ServerStatusStyle.dot(s.level)).frame(width: 7, height: 7)
                    Text(s.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(spacing: 7) {
                    MeterRow(label: "CPU", value: s.cpu, level: .ok)
                    MeterRow(label: "RAM", value: s.memory, level: s.memoryLevel)
                    MeterRow(label: "Disk", value: s.disk, level: s.diskLevel)
                }
                Spacer(minLength: 8)
                FetchedLabel(date: s.fetched, stale: s.isStale(at: now))
            }
            .opacity(s.isStale(at: now) ? 0.55 : 1)
        } else {
            EmptyStatusView()
        }
    }
}

/// Up to three servers, the most urgent first.
struct ServerStatusMediumView: View {
    let snapshots: [ServerSnapshot]
    var now: Date = .now

    var body: some View {
        if snapshots.isEmpty {
            EmptyStatusView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Servers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 0) {
                        ForEach(["CPU", "RAM", "Disk"], id: \.self) { title in
                            Text(LocalizedStringKey(title)).frame(width: 52, alignment: .leading)
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(snapshots.prefix(3)) { s in
                    Spacer(minLength: 6)
                    Link(destination: ServerSnapshots.link(for: s.id)) {
                        HStack(spacing: 6) {
                            Circle().fill(ServerStatusStyle.dot(s.level)).frame(width: 7, height: 7)
                            Text(s.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            HStack(spacing: 0) {
                                MiniMeter(value: s.cpu, level: .ok)
                                MiniMeter(value: s.memory, level: s.memoryLevel)
                                MiniMeter(value: s.disk, level: s.diskLevel)
                            }
                        }
                        .opacity(s.isStale(at: now) ? 0.55 : 1)
                    }
                    .foregroundStyle(.primary)
                }
                Spacer(minLength: 6)
                if let newest = snapshots.map(\.fetched).max() {
                    FetchedLabel(date: newest, stale: snapshots.allSatisfy { $0.isStale(at: now) })
                }
            }
        }
    }
}

private struct MeterRow: View {
    let label: LocalizedStringKey
    let value: Double?
    let level: ServerSnapshot.Level

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(ServerStatusStyle.percent(value))
                    .foregroundStyle(level == .ok ? Color.primary : ServerStatusStyle.color(level))
                    .fontWeight(level == .ok ? .regular : .semibold)
            }
            .font(.caption.monospacedDigit())
            Bar(value: value, level: level).frame(height: 4)
        }
    }
}

private struct MiniMeter: View {
    let value: Double?
    let level: ServerSnapshot.Level

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ServerStatusStyle.percent(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(level == .ok ? Color.primary : ServerStatusStyle.color(level))
                .fontWeight(level == .ok ? .regular : .semibold)
            Bar(value: value, level: level).frame(width: 40, height: 3)
        }
        .frame(width: 52, alignment: .leading)
    }
}

private struct Bar: View {
    let value: Double?
    let level: ServerSnapshot.Level

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                if let value {
                    Capsule().fill(ServerStatusStyle.color(level))
                        .frame(width: max(2, geo.size.width * min(max(value, 0), 1)))
                }
            }
        }
    }
}

private struct FetchedLabel: View {
    let date: Date
    let stale: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
            // The time of the fetch: calm (no ticking seconds) and exact.
            if Calendar.current.isDateInToday(date) {
                Text(date, style: .time)
            } else {
                Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct EmptyStatusView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "server.rack").font(.title3).foregroundStyle(.secondary)
            Text("No server status yet").font(.subheadline.weight(.semibold))
            Text("Open a server's dashboard in Deckhand once.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
