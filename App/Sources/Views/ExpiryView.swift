import DeckhandCore
import SwiftUI

/// Certificates and domain registrations with days left; the server checks daily and pushes at 30, 7 and 1 days.
struct ExpiryView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var status: Expiry.Status?
    @State private var newDomain = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let status {
                if !status.installed {
                    Section {
                        Text("The server checks your certificates and domain registrations once a day and sends a push 30, 7 and 1 days before one expires.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { Task { await perform(Expiry.installCommand(topic: topic, server: server.id)) } } label: {
                            HStack { Text("Turn on").font(.headline); Spacer(); if busy { ProgressView() } }
                        }
                        .disabled(busy)
                        .accessibilityIdentifier("expiry.install")
                    }
                } else {
                    Section {
                        if status.entries.isEmpty { Text("Add the domains to watch.").foregroundStyle(.secondary) }
                        ForEach(status.entries) { e in row(e) }
                    } footer: {
                        if let checked = status.entries.compactMap(\.checked).max() {
                            Text("Checked \(checked.formatted(.relative(presentation: .named))). Pushes at 30, 7 and 1 days left.")
                        }
                    }
                    Section {
                        HStack {
                            TextField("example.com", text: $newDomain).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .accessibilityIdentifier("expiry.domain")
                            Button("Add") { Task { await add(newDomain) } }
                                .disabled(!Expiry.isValidDomain(newDomain.trimmingCharacters(in: .whitespaces)) || busy)
                                .accessibilityIdentifier("expiry.add")
                        }
                        ForEach(status.suggestions, id: \.self) { s in
                            Button { Task { await add(s) } } label: { Label(s, systemImage: "plus.circle") }
                                .accessibilityIdentifier("expiry.suggest.\(s)")
                        }
                    } header: {
                        Text("Watch a domain")
                    } footer: {
                        if !status.suggestions.isEmpty { Text("Suggestions from your uptime checks and web servers.") }
                    }
                    Section {
                        Button { Task { await perform(Expiry.runNowCommand) } } label: {
                            HStack { Label("Check now", systemImage: "arrow.clockwise"); Spacer(); if busy { ProgressView() } }
                        }
                        .disabled(busy || status.entries.isEmpty)
                        .accessibilityIdentifier("expiry.run")
                        Button("Turn off", role: .destructive) { Task { await perform(Expiry.uninstallCommand) } }
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Certificates and domains")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private var topic: String {
        if settings.ntfyTopicURL.isEmpty { settings.ntfyTopicURL = TaskNotifier.newTopicURL() }
        return settings.ntfyTopicURL
    }

    private func row(_ e: Expiry.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(e.domain).font(.body.weight(.medium))
            HStack(spacing: 14) {
                days("lock", String(localized: "Certificate"), e.daysLeft(e.certificateEnd))
                days("calendar", String(localized: "Domain"), e.daysLeft(e.registrationEnd))
            }
            if !e.issuer.isEmpty { Text(e.issuer).font(.caption).foregroundStyle(.secondary) }
        }
        .swipeActions { Button("Remove", role: .destructive) { Task { await perform(Expiry.removeCommand(e.domain)) } } }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("expiry.\(e.domain)")
    }

    private func days(_ symbol: String, _ title: String, _ left: Int?) -> some View {
        let color: Color = switch left {
        case nil: .secondary
        case let d? where d < 0: .red
        case let d? where d <= 7: .red
        case let d? where d <= 30: .orange
        default: .green
        }
        let text = switch left {
        case nil: String(localized: "unknown")
        case let d? where d < 0: String(localized: "expired")
        case let d?: String(localized: "\(d) days")
        }
        return Label { Text("\(title): \(text)").font(.caption.monospacedDigit()) } icon: { Image(systemName: symbol).font(.caption) }
            .foregroundStyle(color)
    }

    private func add(_ domain: String) async {
        let d = domain.trimmingCharacters(in: .whitespaces).lowercased()
        await perform(Expiry.addCommand(d) + "\n" + Expiry.runNowCommand)
        newDomain = ""
    }

    private func perform(_ command: String) async {
        busy = true
        defer { busy = false }
        do {
            let conn = try await connections.connection(for: server)
            let out = try await conn.run(command, timeout: .seconds(180)).stdout
            if out.contains("@@nocron") { error = String(localized: "This server has no cron, so daily checks can't run.") }
            else if let f = out.split(separator: "\n").first(where: { $0.hasPrefix("@@failed") }) { error = String(f.dropFirst(9)) }
            else { error = nil }
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            status = Expiry.parseStatus(try await conn.run(Expiry.statusCommand, timeout: .seconds(30)).stdout)
        } catch { self.error = error.localizedDescription }
    }
}
