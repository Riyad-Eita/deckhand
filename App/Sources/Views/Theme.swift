import DeckhandCore
import SwiftUI

/// Deckhand's design system: graphite and paper, one blue accent, monospaced detail, brand marks for integrations.
enum Theme {
    static let accent = Color.accentColor
    static let mono = Font.system(.footnote, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
    static let corner: CGFloat = 14

    /// Card surface that sits on grouped backgrounds in light and dark mode.
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let hairline = Color.primary.opacity(0.08)
    static let userBubble = Color.accentColor
    static let codeBackground = Color.primary.opacity(0.05)

    static func statusColor(_ state: Connections.State) -> Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .idle: .secondary.opacity(0.4)
        }
    }
}

struct StatusDot: View {
    let state: Connections.State
    var body: some View {
        Circle()
            .fill(Theme.statusColor(state))
            .frame(width: 8, height: 8)
            .overlay {
                if state == .connected {
                    Circle().stroke(Color.green.opacity(0.35), lineWidth: 4).blur(radius: 1)
                }
            }
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

/// Logos of the services Deckhand works with, used to show compatibility.
enum Brand: String, CaseIterable {
    case claude, anthropic, openai, codex, github, openrouter, mcp, ollama, gemini

    var asset: String { "brand-\(rawValue)" }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341) // Claude's coral
        case .gemini: Color(red: 0.557, green: 0.459, blue: 0.698)
        case .openrouter: Color(red: 0.396, green: 0.400, blue: 0.945)
        default: .primary
        }
    }

    static func forProvider(_ kind: ProviderKind) -> Brand? {
        switch kind {
        case .anthropic: .claude
        case .openAI: .openai
        case .openRouter: .openrouter
        case .custom: nil
        }
    }
}

/// A brand mark in a soft rounded tile.
struct BrandIcon: View {
    let brand: Brand?
    var fallback: String = "key.horizontal"
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).stroke(Theme.hairline))
            if let brand {
                Image(brand.asset)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(brand.tint)
                    .padding(size * 0.2)
            } else {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Engine {
    @MainActor var brand: Brand? {
        switch self {
        case .ownKey: Brand.forProvider(AppSettings.shared.providerKind)
        case .codex: .codex
        case .claudeCode: .claude
        }
    }

    var shortTitle: String {
        switch self {
        case .ownKey: "Your key"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

extension ServerCLI {
    var brand: Brand { self == .codex ? .codex : .claude }
}

/// Row content for tappable list rows: primary title, secondary subtitle, never tinted.
struct RowLabel<Icon: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
