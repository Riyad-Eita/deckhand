import SwiftUI
import WidgetKit

struct ServerStatusEntry: TimelineEntry {
    let date: Date
    let snapshots: [ServerSnapshot]
}

struct ServerStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> ServerStatusEntry {
        ServerStatusEntry(date: .now, snapshots: [
            ServerSnapshot(id: UUID(), name: "my-server", cpu: 0.12, memory: 0.48, disk: 0.61, diskMount: "/", fetched: .now),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ServerStatusEntry) -> Void) {
        let saved = ServerSnapshots.ordered(ServerSnapshots.load())
        completion(saved.isEmpty && context.isPreview ? placeholder(in: context) : ServerStatusEntry(date: .now, snapshots: saved))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ServerStatusEntry>) -> Void) {
        // The app reloads the widget after each fetch; the hourly entry only dims values that got old.
        let entry = ServerStatusEntry(date: .now, snapshots: ServerSnapshots.ordered(ServerSnapshots.load()))
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct ServerStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ServerSnapshots.widgetKind, provider: ServerStatusProvider()) { entry in
            ServerStatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Server status")
        .description("CPU, memory and disk of your servers, from the last check in Deckhand.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ServerStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ServerStatusEntry

    var body: some View {
        switch family {
        case .systemMedium:
            ServerStatusMediumView(snapshots: entry.snapshots, now: entry.date)
        default:
            ServerStatusSmallView(snapshot: entry.snapshots.first, now: entry.date)
                .widgetURL(entry.snapshots.first.map { ServerSnapshots.link(for: $0.id) })
        }
    }
}
