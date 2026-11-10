import DeckhandCore
import SwiftData
import SwiftUI

/// First launch: welcome → add a server → pick how agents work. Every step can be skipped.
struct OnboardingView: View {
    let finish: () -> Void

    enum Step: Int { case welcome, server, engine }

    @Environment(\.modelContext) private var context
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @State private var step: Step = .welcome
    @State private var addingServer = false
    @State private var signIn: ServerCLI?
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ProgressDots(current: step.rawValue, count: 3)
                Spacer()
                Button("Skip") { finish() }.font(.subheadline)
            }
            .padding(.horizontal, 24).padding(.top, 16)

            TabView(selection: $step) {
                welcome.tag(Step.welcome)
                server.tag(Step.server)
                engine.tag(Step.engine)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: step)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $addingServer) { ServerEditorView(server: nil) }
        .sheet(item: $signIn) { cli in
            if let s = servers.first { CLILoginView(server: s, cli: cli) { ok in if ok { finish() } } }
        }
        .sheet(isPresented: $showingSettings, onDismiss: { if AppSettings.shared.isConfigured { finish() } }) { SettingsView() }
        .onChange(of: servers.count) { _, count in if count > 0 && step == .server { step = .engine } }
    }

    // MARK: Steps

    private var welcome: some View {
        StepPage(
            title: "Your servers, in your pocket",
            subtitle: "Deckhand connects to your Linux servers over SSH and lets AI agents do the work — from your iPhone."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "sparkles", title: "Agents on your server", text: "Claude Code, Codex or your own model key fix, build and explain things for you.")
                Feature(symbol: "terminal", title: "A real terminal", text: "Sessions keep running when the connection drops.")
                Feature(symbol: "lock.shield", title: "Private by design", text: "No account, no tracking. Keys stay in your iPhone's Keychain.")
            }
        } action: {
            Button { step = .server } label: { Text("Get Started").frame(maxWidth: .infinity) }
        }
    }

    private var server: some View {
        StepPage(
            title: "Add your server",
            subtitle: "Host, user and password are enough — Deckhand swaps the password for a secure key it creates on this iPhone."
        ) {
            if let s = servers.first {
                Label("\(s.displayName) is ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 54, weight: .light)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
            }
        } action: {
            if servers.isEmpty {
                Button { addingServer = true } label: { Text("Add Server").frame(maxWidth: .infinity) }
                    .accessibilityIdentifier("onboarding.addServer")
            } else {
                Button { step = .engine } label: { Text("Continue").frame(maxWidth: .infinity) }
            }
        }
    }

    private var engine: some View {
        StepPage(
            title: "Pick your agent",
            subtitle: "Use the plan you already pay for — the agent then runs on your server. Or bring an API key and the agent runs on this iPhone."
        ) {
            VStack(spacing: 10) {
                EngineChoice(brand: .claude, title: "Claude Code", detail: "Sign in with your Claude plan") { signIn = .claudeCode }
                EngineChoice(brand: .codex, title: "Codex", detail: "Sign in with your ChatGPT plan") { signIn = .codex }
                EngineChoice(brand: nil, title: "Your own API key", detail: "Claude, OpenAI, OpenRouter or a local model") { showingSettings = true }
            }
            .disabled(servers.isEmpty && false)
        } action: {
            Button { finish() } label: { Text("Later").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        }
    }
}

private struct StepPage<Content: View, Action: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var content: () -> Content
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(subtitle).font(.body).foregroundStyle(.secondary)
            }
            content()
            Spacer()
            action()
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(24)
    }
}

private struct Feature: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EngineChoice: View {
    let brand: Brand?
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                BrandIcon(brand: brand, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

private struct ProgressDots: View {
    let current: Int
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i <= current ? Theme.accent : Color.primary.opacity(0.15))
                    .frame(width: i == current ? 22 : 8, height: 8)
            }
        }
        .animation(.snappy, value: current)
    }
}
