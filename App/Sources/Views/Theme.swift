import SwiftUI

/// Deckhand's look: warm paper and ink, one signal colour, monospaced detail.
enum Theme {
    static let signal = Color("AccentColor")
    static let mono = Font.system(.footnote, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)

    static func statusColor(_ state: Connections.State) -> Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .idle: .secondary.opacity(0.5)
        }
    }
}

struct StatusDot: View {
    let state: Connections.State
    var body: some View {
        Circle()
            .fill(Theme.statusColor(state))
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .failed: "Connection failed"
        case .idle: "Not connected"
        }
    }
}
