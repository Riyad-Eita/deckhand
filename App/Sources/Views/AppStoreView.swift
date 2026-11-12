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
            Section {
                NavigationLink { ReviewsView(app: app) } label: { Label("Ratings and reviews", systemImage: "star.bubble") }
                    .accessibilityIdentifier("asc.reviews")
            }
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

/// Ratings and reviews of one app: filter by stars, draft a reply in the review's language, edit, post.
struct ReviewsView: View {
    let app: AppStoreConnect.App
    @State private var reviews: [AppStoreConnect.Review]?
    @State private var filter = 0
    @State private var error: String?
    @State private var replying: AppStoreConnect.Review?

    private var shown: [AppStoreConnect.Review] {
        (reviews ?? []).filter {
            switch filter { case 1: $0.rating <= 2; case 2: $0.rating == 3; case 3: $0.rating >= 4; default: true }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Rating", selection: $filter) {
                    Text("All").tag(0); Text("1–2 ★").tag(1); Text("3 ★").tag(2); Text("4–5 ★").tag(3)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reviews.filter")
            }
            if let error { ProblemView(message: error, compact: true) }
            if let reviews {
                if shown.isEmpty { Text(reviews.isEmpty ? "No reviews yet." : "No reviews with this rating.").foregroundStyle(.secondary) }
                ForEach(shown) { r in
                    Button { replying = r } label: { ReviewRow(review: r) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("review.\(r.id)")
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Ratings and reviews")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $replying) { r in ReplySheet(app: app, review: r) { Task { await load() } } }
    }

    private func load() async {
        guard let client = AppStoreAccount.shared.client else { return }
        do { reviews = try await client.reviews(app: app.id); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct ReviewRow: View {
    let review: AppStoreConnect.Review
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(String(repeating: "★", count: review.rating) + String(repeating: "☆", count: max(0, 5 - review.rating)))
                    .foregroundStyle(review.rating <= 2 ? .red : review.rating == 3 ? .orange : .yellow)
                Spacer()
                if let d = review.date { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
            }
            if !review.title.isEmpty { Text(review.title).font(.subheadline.weight(.semibold)) }
            Text(review.body).font(.subheadline).lineLimit(4)
            HStack(spacing: 6) {
                Text("\(review.nickname) · \(review.territory)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if review.response != nil { Label("Answered", systemImage: "arrowshape.turn.up.left.fill").font(.caption).foregroundStyle(.green) }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Draft (on-device model or your key, in the review's language), edit, and post — replacing an earlier reply.
private struct ReplySheet: View {
    let app: AppStoreConnect.App
    let review: AppStoreConnect.Review
    let posted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var notes = ""
    @State private var source: QuickAI.Source?
    @State private var drafting = false
    @State private var posting = false
    @State private var confirm = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { ReviewRow(review: review) }
                if let r = review.response {
                    Section("Your current reply") { Text(r.body).font(.subheadline).foregroundStyle(.secondary) }
                }
                Section {
                    TextField("Notes for the draft (optional): fixed in 1.3, coming next month …", text: $notes, axis: .vertical)
                        .lineLimit(1...3).font(.subheadline)
                    Button { Task { await draft() } } label: {
                        HStack { Label("Draft a reply", systemImage: "sparkles"); Spacer(); if drafting { ProgressView() } }
                    }
                    .disabled(drafting || !QuickAI.isAvailable)
                    .accessibilityIdentifier("reply.draft")
                } footer: {
                    if !QuickAI.isAvailable { Text("Drafts need Apple Intelligence on this iPhone or a model key in Settings — or just write it yourself.") }
                    else if let source {
                        switch source {
                        case .onDevice: Text("Drafted on this iPhone.")
                        case .key(let model): Text("Drafted with your key (\(model)).")
                        }
                    }
                }
                Section {
                    TextEditor(text: $text).frame(minHeight: 140).accessibilityIdentifier("reply.text")
                } header: {
                    Text("Reply")
                } footer: {
                    Text("\(text.count) / 5970 · Public on the App Store once Apple has published it.")
                        .foregroundStyle(text.count > 5970 ? .red : .secondary)
                }
                if let error { ProblemView(message: error, compact: true) }
            }
            .navigationTitle(review.response == nil ? String(localized: "Reply") : String(localized: "Change reply"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { confirm = true }
                        .disabled(posting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 5970)
                        .accessibilityIdentifier("reply.post")
                }
            }
            .confirmationDialog("Post this reply publicly?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Post reply") { Task { await post() } }
            } message: {
                Text(review.response == nil ? "It appears under the review on the App Store." : "It replaces your current reply.")
            }
            .onAppear { if text.isEmpty { text = review.response?.body ?? "" } }
        }
    }

    private func draft() async {
        drafting = true
        defer { drafting = false }
        do {
            if let r = try await QuickAI.run(AppStoreConnect.replyInstructions, AppStoreConnect.replyPrompt(review, app: app.name, notes: notes)) {
                text = r.text.trimmingCharacters(in: .whitespacesAndNewlines); source = r.source; error = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    private func post() async {
        guard let client = AppStoreAccount.shared.client else { return }
        posting = true
        defer { posting = false }
        do {
            try await client.reply(to: review, body: text.trimmingCharacters(in: .whitespacesAndNewlines))
            posted()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
