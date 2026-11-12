import DeckhandCore
import SwiftUI
import UniformTypeIdentifiers

/// App Store Connect: your apps with their review state; per app the versions, builds with TestFlight state and the
/// TestFlight groups with testers. Connected with the user's own API key.
struct AppStoreView: View {
    @State private var account = AppStoreAccount.shared
    @State private var apps: [AppStoreConnect.App]?
    @State private var latest: [String: AppStoreConnect.Version] = [:]
    @State private var error: String?
    @State private var confirmDisconnect = false

    var body: some View {
        Group {
            if account.isConnected {
                List {
                    if let error { ProblemView(message: error, compact: true) }
                    if let apps {
                        Section {
                            if apps.isEmpty { Text("No apps in this team yet.").foregroundStyle(.secondary) }
                            ForEach(apps) { app in
                                NavigationLink { AppStoreAppView(app: app) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(app.name).font(.body.weight(.medium))
                                        if let v = latest[app.id] {
                                            HStack(spacing: 6) {
                                                Text(v.version).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                                StateBadge(state: v.state)
                                            }
                                        } else {
                                            Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .accessibilityIdentifier("asc.app.\(app.name)")
                            }
                        } footer: {
                            Text("Deckhand checks the review state now and then in the background and tells you when it moves on.")
                        }
                    } else if error == nil {
                        HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                    }
                }
                .refreshable { await load() }
                .task { await load() }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { confirmDisconnect = true }
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("More")
                    }
                }
                .confirmationDialog("Disconnect App Store Connect?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) { account.disconnect(); apps = nil; latest = [:] }
                } message: { Text("The API key is removed from this iPhone. It stays valid in App Store Connect until you revoke it there.") }
            } else {
                ConnectAppStoreView { found in apps = found; Task { await load() } }
            }
        }
        .navigationTitle("App Store Connect")
    }

    private func load() async {
        guard let client = account.client else { return }
        do {
            let list = try await client.apps()
            apps = list
            error = nil
            var newest: [(app: AppStoreConnect.App, version: AppStoreConnect.Version)] = []
            await withTaskGroup(of: (AppStoreConnect.App, AppStoreConnect.Version?).self) { group in
                for app in list { group.addTask { (app, try? await client.versions(app: app.id).first) } }
                for await (app, v) in group { if let v { latest[app.id] = v; newest.append((app, v)) } }
            }
            account.remember(newest)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Paste or pick the .p8, key ID and issuer ID; checked against App Store Connect before it's kept.
private struct ConnectAppStoreView: View {
    let connected: ([AppStoreConnect.App]) -> Void
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var privateKey = ""
    @State private var fileName: String?
    @State private var importing = false
    @State private var busy = false
    @State private var error: String?

    private var valid: Bool { !keyID.isEmpty && !issuerID.isEmpty && privateKey.contains("PRIVATE KEY") }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "app.badge.checkmark").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.accent)
                    Text("Builds, TestFlight and reviews").font(.headline)
                    Text("Follow your apps without the web dashboard, and get a notification when a review moves on.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if let error { ProblemView(message: error, compact: true) }
            Section {
                Button { importing = true } label: {
                    HStack {
                        Label(fileName ?? String(localized: "Choose the .p8 file"), systemImage: privateKey.isEmpty ? "doc.badge.plus" : "checkmark.seal.fill")
                        Spacer()
                    }
                }
                .accessibilityIdentifier("asc.file")
                TextField("Key ID", text: $keyID).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.body.monospaced())
                    .accessibilityIdentifier("asc.keyID")
                TextField("Issuer ID", text: $issuerID).textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                    .accessibilityIdentifier("asc.issuer")
            } header: {
                Text("API key")
            } footer: {
                Text("App Store Connect → Users and Access → Integrations → Team Keys. A key with the Developer role is enough. The key stays in this iPhone's Keychain; the app talks to Apple directly.")
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack { Text("Connect").font(.headline); Spacer(); if busy { ProgressView() } }
                }
                .disabled(!valid || busy)
                .accessibilityIdentifier("asc.connect")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("PRIVATE KEY") else {
                error = AppStoreConnect.Failure.badKey.localizedDescription; return
            }
            privateKey = text
            fileName = url.lastPathComponent
            if keyID.isEmpty, let id = AppStoreConnect.Credentials.keyID(fromFileName: url.lastPathComponent) { keyID = id }
            error = nil
        }
        #if DEBUG
        .task {
            // DECKHAND_SEED_ASC_KEY="<key id>|<issuer>|<base64 .p8>" fills the form (UI tests).
            let raw = ProcessInfo.processInfo.environment["DECKHAND_SEED_ASC_KEY"] ?? ""
            let p = raw.split(separator: "|").map(String.init)
            if p.count == 3, let d = Data(base64Encoded: p[2]), let pem = String(data: d, encoding: .utf8) {
                keyID = p[0]; issuerID = p[1]; privateKey = pem; fileName = "AuthKey_\(p[0]).p8"
            }
        }
        #endif
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        do {
            let apps = try await AppStoreAccount.shared.connect(.init(keyID: keyID, issuerID: issuerID, privateKey: privateKey))
            TaskNotifier.shared.requestPermission()
            connected(apps)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One app: App Store versions with review state, recent builds with TestFlight state, TestFlight groups and testers.
struct AppStoreAppView: View {
    let app: AppStoreConnect.App
    @State private var overview: AppStoreConnect.Overview?
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let o = overview {
                Section("App Store") {
                    if o.versions.isEmpty { Text("No versions yet.").foregroundStyle(.secondary) }
                    ForEach(o.versions) { v in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.platform == "IOS" ? v.version : "\(v.version) · \(platformName(v.platform))").font(.body.monospacedDigit().weight(.medium))
                                if let d = v.created { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            StateBadge(state: v.state)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section("Builds") {
                    if o.builds.isEmpty { Text("No builds uploaded yet.").foregroundStyle(.secondary) }
                    ForEach(o.builds) { b in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(b.version) (\(b.number))").font(.body.monospacedDigit().weight(.medium))
                                Spacer()
                                if b.expired { StateBadge(state: "EXPIRED") }
                                else if b.processing != "VALID" { StateBadge(state: b.processing) }
                                else if let s = b.internalState { StateBadge(state: s) }
                            }
                            HStack(spacing: 6) {
                                if let d = b.uploaded { Text(d.formatted(.relative(presentation: .named))) }
                                if let e = b.externalState, b.processing == "VALID", !b.expired {
                                    Text("·")
                                    Text("External: \(AppStoreConnect.describe(e))")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("asc.build.\(b.number)")
                    }
                }
                Section {
                    if o.groups.isEmpty { Text("No TestFlight groups yet.").foregroundStyle(.secondary) }
                    ForEach(o.groups) { g in
                        DisclosureGroup {
                            if g.testers.isEmpty { Text("No testers").foregroundStyle(.secondary) }
                            ForEach(g.testers) { t in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.name.isEmpty ? t.email : t.name)
                                        if !t.name.isEmpty { Text(t.email).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    StateBadge(state: t.state)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: g.isInternal ? "person.2" : "globe").foregroundStyle(.secondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.name).font(.body.weight(.medium))
                                    Text(g.isInternal ? String(localized: "Internal") : g.publicLink ? String(localized: "External · public link") : String(localized: "External"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(g.testers.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("asc.group.\(g.name)")
                    }
                } header: {
                    Text("TestFlight")
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func platformName(_ p: String) -> String {
        switch p { case "MAC_OS": "macOS"; case "TV_OS": "tvOS"; case "VISION_OS": "visionOS"; default: p }
    }

    private func load() async {
        guard let client = AppStoreAccount.shared.client else { return }
        do {
            overview = try await client.overview(app: app.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A review / build / tester state: a colored dot and a plain name.
struct StateBadge: View {
    let state: String
    var body: some View {
        let color: Color = switch AppStoreConnect.tone(state) {
        case .good: .green
        case .waiting: .orange
        case .bad: .red
        case .neutral: .secondary
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(LocalizedStringKey(AppStoreConnect.describe(state))).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}
