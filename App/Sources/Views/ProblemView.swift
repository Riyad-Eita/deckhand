import DeckhandCore
import SwiftUI

/// An error in plain words with what to do about it.
struct ProblemView: View {
    let message: String
    var compact = false

    private var problem: Problem { Problem.from(message) }

    var symbol: String {
        switch problem.kind {
        case .network: "wifi.exclamationmark"
        case .signIn: "person.badge.key"
        case .hostKey: "exclamationmark.shield"
        case .server: "server.rack"
        case .provider: "cloud.bolt"
        case .limit: "hourglass"
        case .other: "exclamationmark.triangle"
        }
    }

    var body: some View {
        if compact {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.message).foregroundStyle(.red)
                    Text(problem.suggestion).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: symbol).foregroundStyle(.red) }
            .font(.footnote)
        } else {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text(problem.message).font(.headline).multilineTextAlignment(.center)
                Text(problem.suggestion).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
    }
}
