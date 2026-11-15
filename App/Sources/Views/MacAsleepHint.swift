import SwiftUI

/// Under a connection error to a Mac: the usual reason is that it's asleep or Remote Login is off.
struct MacAsleepHint: View {
    var body: some View {
        Label {
            Text("Is the Mac asleep? A sleeping Mac can't answer. Wake it, or on the Mac turn on \"Prevent automatic sleeping when the display is off\" (System Settings → Energy) and check that Remote Login is on.")
        } icon: {
            Image(systemName: "moon.zzz")
        }
        .font(.footnote).foregroundStyle(.secondary)
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.horizontal)
        .accessibilityIdentifier("server.macAsleep")
    }
}
