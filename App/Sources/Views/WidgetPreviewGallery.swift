#if DEBUG
import SwiftUI

/// DECKHAND_WIDGET_PREVIEW=demo|live: the status widget's faces at home-screen size, for screenshots and tests
/// (the simulator's home screen can't be scripted). `live` shows what the app saved for the real widget.
struct WidgetPreviewGallery: View {
    let live: Bool

    private var snapshots: [ServerSnapshot] {
        if live { return ServerSnapshots.ordered(ServerSnapshots.load()) }
        let t = Date.now.addingTimeInterval(-180)
        return ServerSnapshots.ordered([
            ServerSnapshot(id: UUID(), name: "web-1", cpu: 0.34, memory: 0.58, disk: 0.96, diskMount: "/", fetched: t),
            ServerSnapshot(id: UUID(), name: "db", cpu: 0.12, memory: 0.71, disk: 0.87, diskMount: "/var/lib", fetched: t),
            ServerSnapshot(id: UUID(), name: "staging", cpu: 0.05, memory: 0.33, disk: 0.41, diskMount: "/", fetched: t),
        ])
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack(spacing: 24) {
                    tile { ServerStatusSmallView(snapshot: snapshots.first) }
                        .frame(width: 170, height: 170)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("widget.small")
                    if snapshots.count > 1 {
                        tile { ServerStatusSmallView(snapshot: snapshots.last) }
                            .frame(width: 170, height: 170)
                    }
                }
                tile { ServerStatusMediumView(snapshots: snapshots) }
                    .frame(width: 364, height: 170)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("widget.medium")
                tile { ServerStatusSmallView(snapshot: nil) }
                    .frame(width: 170, height: 170)
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
#endif
