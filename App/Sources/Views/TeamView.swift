import DeckhandCore
import DeckhandSSH
import SwiftUI
import UIKit

/// People on a server: invite someone with their own account and the rights you choose (they join by scanning a QR
/// code), see who has access, change a role or take access away.
struct TeamView: View {
    let server: Server
    private var connections: Connections { .shared }
    @State private var root = RootRunner()
    @State private var entries: [Team.Entry]?
    @State private var noSudo = false
    @State private var error: String?
    @State private var inviting = false
    @State private var sharingOwn = false
    @State private var editing: Team.Member?
    @State private var removing: Team.Member?
    @State private var shownCode: InviteCode?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if noSudo {
                Section {
                    Label("You can't use sudo on this server, so Deckhand can't create accounts for other people. Sign in as root or an admin user to invite someone.", systemImage: "person.badge.key")
                        .font(.subheadline)
                    Button("Share My Own Access Instead…") { sharingOwn = true }
                        .accessibilityIdentifier("team.shareOwn")
                } footer: {
                    Text("That lets them in as you: same files, same rights, and you can't tell apart what they do. Only for people you'd give your password to.")
                }
            }
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("Nobody else yet", systemImage: "person.2",
                                           description: Text("Invite someone: they get their own account with the rights you pick and join by scanning a QR code. Your password or key is never shared."))
                } else {
                    Section("People") {
                        ForEach(entries) { e in
                            Button { editing = e.member } label: { MemberRow(entry: e) }
                                .buttonStyle(.plain)
                                .swipeActions(allowsFullSwipe: false) {
                                    Button("Remove") { removing = e.member }.tint(.red)
                                }
                                .accessibilityIdentifier("team.member")
                        }
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("People")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { inviting = true } label: { Label("Invite Someone", systemImage: "person.badge.plus") }
                    .disabled(noSudo)
                    .accessibilityIdentifier("team.invite")
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sudoPassword(root, server: server)
        .appSheet(isPresented: $inviting) {
            InviteSheet(server: server) { code in
                inviting = false
                shownCode = code
                Task { await load() }
            }
        }
        .appSheet(item: $editing) { m in
            MemberSheet(server: server, member: m) { code in
                editing = nil
                if let code { shownCode = code }
                Task { await load() }
            }
        }
        .appSheet(item: $shownCode) { InviteCodeView(code: $0) }
        .confirmationDialog("Remove \(removing?.person ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Account", role: .destructive) { if let m = removing { Task { await remove(m) } } }
                .accessibilityIdentifier("team.remove.confirm")
        } message: {
            Text("Their account \(removing?.user ?? "") and its home folder are deleted and running sessions end. This can't be undone.")
        }
        .confirmationDialog("Share your own access?", isPresented: $sharingOwn, titleVisibility: .visible) {
            Button("Show a Code for My Account", role: .destructive) { Task { await shareOwn() } }
        } message: {
            Text("The person who scans it signs in as \(server.username), with all your rights. You can remove their key later under SSH keys.")
        }
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DECKHAND_TEAM_DEMO"] == "1" { entries = TeamDemo.entries; return }
        #endif
        do {
            let conn = try await connections.connection(for: server)
            let members = Team.parseRecords(try await conn.run(Team.recordsCommand, timeout: .seconds(15)).stdout)
            let access = try await RootAccess.shared.access(for: server, connection: conn)
            noSudo = access == .unavailable
            if members.isEmpty || noSudo {
                entries = Team.entries(members, status: "")
            } else if await root.run(Team.statusScript(users: members.map(\.user)), on: server) {
                entries = Team.entries(members, status: root.lines.joined(separator: "\n"))
            } else {
                entries = Team.entries(members, status: "")
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ m: Team.Member) async {
        removing = nil
        guard await root.run(Team.removeScript(m), on: server) else {
            error = root.lines.contains("@@notours") ? String(localized: "\(m.user) wasn't created by Deckhand, so it isn't removed from here.")
                : root.lines.last ?? String(localized: "Removing the account didn't work.")
            return
        }
        if let conn = try? await connections.connection(for: server) { _ = try? await conn.run(Team.forgetCommand(user: m.user), timeout: .seconds(10)) }
        await load()
    }

    private func shareOwn() async {
        do {
            let conn = try await connections.connection(for: server)
            let key = PairingClient.makeOneTimeKey()
            let id = InviteCode.newID()
            let until = Date().addingTimeInterval(3600)
            let out = try await conn.run(Team.shareOwnAccessCommand(oneTimePublicKey: key.publicKey, id: id, until: until), timeout: .seconds(20))
            guard out.stdout.contains("@@invited") else { throw CLIError(out.stderr.isEmpty ? out.stdout : out.stderr) }
            shownCode = try InviteCode.make(server: server, user: server.username, seed: key.seed, until: until, person: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MemberRow: View {
    let entry: Team.Entry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.member.role == .admin ? "person.badge.shield.checkmark" : entry.member.role == .developer ? "person.badge.key" : "person")
                .font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.member.person).font(.body.weight(.medium))
                Text("\(entry.member.user) · \(entry.member.role.title)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            state.font(.caption2.weight(.semibold))
        }
    }

    @ViewBuilder private var state: some View {
        switch entry.state() {
        case .invited: Text("Invited").foregroundStyle(.orange)
        case .inviteExpired: Text("Code expired").foregroundStyle(.secondary)
        case .active:
            if let last = entry.lastLogin { Text(last, format: .relative(presentation: .named)).foregroundStyle(.green) } else { Text("Joined").foregroundStyle(.green) }
        case .expired: Text("Account ended").foregroundStyle(.secondary)
        case .removed: Text("Removed").foregroundStyle(.red)
        }
    }
}

/// A code to show: the link, who it is for, until when.
struct InviteCode: Identifiable {
    let id = UUID()
    let link: String
    let person: String?
    let user: String
    let until: Date

    static func newID() -> String { (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    @MainActor static func make(server: Server, user: String, seed: Data, until: Date, person: String?) throws -> InviteCode {
        guard let pinned = server.pinnedHostKey else { throw CLIError(String(localized: "Connect to the server once first.")) }
        let code = Pairing.Code(host: server.host, port: server.port, user: user, name: server.displayName, seed: seed,
                                fingerprints: [SSHKeys.fingerprint(openSSHPublicKey: pinned)], expires: until)
        return InviteCode(link: Pairing.link(code), person: person, user: user, until: until)
    }
}

/// The QR code a teammate scans.
struct InviteCodeView: View {
    let code: InviteCode
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let qr = QRCode.image(code.link) {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260).padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Invite code")
                            .accessibilityIdentifier("team.qr")
                    }
                    Text(code.person.map { String(localized: "For \($0), signing in as \(code.user)") } ?? String(localized: "Signs in as \(code.user)"))
                        .font(.headline)
                    Text("They scan it with the Camera on their \(Device.name) (Deckhand installed). Works once, until \(code.until.formatted(date: .abbreviated, time: .shortened)). Anyone holding this code until then can join — send it only to them.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    ShareLink(item: code.link) { Label("Send the Link", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("team.shareLink")
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Invite Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Who, which role, which groups and folders, until when.
private struct InviteSheet: View {
    let server: Server
    let done: (InviteCode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var root = RootRunner()
    @State private var person = ""
    @State private var user = ""
    @State private var userEdited = false
    @State private var role: Team.Role = .developer
    @State private var groups: Set<String> = []
    @State private var available: [String] = []
    @State private var folders: [String] = []
    @State private var newFolder = ""
    @State private var ends = false
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var validHours = 24
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $person).accessibilityIdentifier("invite.person")
                        .onChange(of: person) { if !userEdited { user = Team.suggestedUser(for: person) } }
                    TextField("User name on the server", text: Binding(get: { user }, set: { user = $0; userEdited = true }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(Theme.mono)
                        .accessibilityIdentifier("invite.user")
                } footer: {
                    if !user.isEmpty && !Team.isValidUser(user) { Text("Lowercase letters, digits, - and _; starting with a letter.").foregroundStyle(.red) }
                }
                Section {
                    Picker("Role", selection: $role) { ForEach(Team.Role.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("invite.role")
                } footer: { Text(role.explanation) }
                if role == .developer {
                    if !available.isEmpty {
                        Section("Groups") {
                            ForEach(available, id: \.self) { g in
                                Toggle(g, isOn: Binding(get: { groups.contains(g) }, set: { if $0 { groups.insert(g) } else { groups.remove(g) } }))
                                    .font(Theme.mono)
                            }
                        }
                    }
                    Section {
                        ForEach(folders, id: \.self) { Text($0).font(Theme.mono) }
                            .onDelete { folders.remove(atOffsets: $0) }
                        HStack {
                            TextField("/srv/my-app", text: $newFolder).textInputAutocapitalization(.never).autocorrectionDisabled().font(Theme.mono)
                                .accessibilityIdentifier("invite.folder")
                            Button("Add") {
                                let f = newFolder.trimmingCharacters(in: .whitespaces)
                                if f.hasPrefix("/"), f != "/", !folders.contains(f) { folders.append(f) }
                                newFolder = ""
                            }
                            .disabled(!newFolder.hasPrefix("/"))
                        }
                    } header: { Text("Folders they may change") } footer: { Text("Everything inside, also files added later. Needs the acl package on the server.") }
                }
                Section {
                    Toggle("Account ends", isOn: $ends)
                    if ends { DatePicker("Last day", selection: $endDate, in: Date()..., displayedComponents: .date) }
                    Picker("Code works for", selection: $validHours) {
                        Text("1 hour").tag(1); Text("24 hours").tag(24); Text("7 days").tag(168)
                    }
                } footer: {
                    Text("An ended account is locked on the server by itself, also while your \(Device.name) is off.")
                }
                if let error { ProblemView(message: error, compact: true) }
                Section {
                    Button { Task { await invite() } } label: {
                        HStack { Text("Create Account and Show Code"); Spacer(); if busy { ProgressView() } }
                    }
                    .disabled(busy || person.trimmingCharacters(in: .whitespaces).isEmpty || !Team.isValidUser(user))
                    .accessibilityIdentifier("invite.create")
                }
            }
            .navigationTitle("Invite Someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sudoPassword(root, server: server)
            .task { await loadGroups() }
        }
    }

    private func loadGroups() async {
        guard let conn = try? await Connections.shared.connection(for: server),
              let out = try? await conn.run("for g in docker www-data adm systemd-journal sudo git; do getent group $g >/dev/null && echo $g; done; true", timeout: .seconds(10)).stdout
        else { return }
        available = out.split(separator: "\n").map(String.init).filter { $0 != "sudo" }
    }

    private func invite() async {
        busy = true
        defer { busy = false }
        error = nil
        let until = Date().addingTimeInterval(Double(validHours) * 3600)
        let last = ends ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDate)) : nil
        let member = Team.Member(user: user, person: person.trimmingCharacters(in: .whitespaces), role: role, groups: Array(groups).sorted(),
                                 folders: folders, expires: last, inviteUntil: until)
        let key = PairingClient.makeOneTimeKey()
        let id = InviteCode.newID()
        let ok = await root.run(Team.inviteScript(member, oneTimePublicKey: key.publicKey, id: id), on: server)
        guard ok, root.lines.contains("@@invited") else {
            error = root.lines.contains("@@exists") ? String(localized: "There's already an account called \(user) on this server. Pick another user name.")
                : [root.failedStep.map { String(localized: "Failed at: \($0)") }, root.lines.last].compactMap { $0 }.joined(separator: "\n")
            if error?.isEmpty ?? true { error = String(localized: "Creating the account didn't work.") }
            return
        }
        do {
            let conn = try await Connections.shared.connection(for: server)
            _ = try await conn.run(Team.saveCommand(member), timeout: .seconds(10))
            let code = try InviteCode.make(server: server, user: user, seed: key.seed, until: until, person: member.person)
            done(code)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One person: change the role, a new code, or remove.
private struct MemberSheet: View {
    let server: Server
    let member: Team.Member
    let done: (InviteCode?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var root = RootRunner()
    @State private var role: Team.Role = .readOnly
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("User name", value: member.user)
                    LabeledContent("Invited", value: member.invited.formatted(date: .abbreviated, time: .omitted))
                    if let e = member.expires { LabeledContent("Account ends", value: e.formatted(date: .abbreviated, time: .omitted)) }
                    if !member.groups.isEmpty { LabeledContent("Groups", value: member.groups.joined(separator: ", ")) }
                    ForEach(member.folders, id: \.self) { LabeledContent("Can change", value: $0) }
                }
                Section {
                    Picker("Role", selection: $role) { ForEach(Team.Role.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    Button("Change Role") { Task { await change() } }
                        .disabled(busy || role == member.role)
                        .accessibilityIdentifier("member.change")
                } footer: { Text(role == .developer && member.role != .developer ? String(localized: "Groups and folders can be picked when you invite someone; changing to developer keeps none.") : role.explanation) }
                Section {
                    Button("New Invite Code") { Task { await reinvite() } }
                        .disabled(busy)
                        .accessibilityIdentifier("member.reinvite")
                } footer: { Text("For when the first code expired or got lost. The old one stops working.") }
                if let error { ProblemView(message: error, compact: true) }
            }
            .navigationTitle(member.person)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sudoPassword(root, server: server)
            .onAppear { role = member.role }
        }
    }

    private func change() async {
        busy = true
        defer { busy = false }
        var new = member
        new.role = role
        if role != .developer { new.groups = []; new.folders = [] }
        guard await root.run(Team.changeScript(from: member, to: new), on: server), root.lines.contains("@@changed") else {
            error = root.lines.last ?? String(localized: "Changing the role didn't work.")
            return
        }
        if let conn = try? await Connections.shared.connection(for: server) { _ = try? await conn.run(Team.saveCommand(new), timeout: .seconds(10)) }
        done(nil)
    }

    private func reinvite() async {
        busy = true
        defer { busy = false }
        let key = PairingClient.makeOneTimeKey()
        let until = Date().addingTimeInterval(24 * 3600)
        guard await root.run(Team.reinviteScript(user: member.user, oneTimePublicKey: key.publicKey, id: InviteCode.newID(), until: until), on: server),
              root.lines.contains("@@invited") else {
            error = root.lines.last ?? String(localized: "Making a new code didn't work.")
            return
        }
        var updated = member
        updated.inviteUntil = until
        if let conn = try? await Connections.shared.connection(for: server) { _ = try? await conn.run(Team.saveCommand(updated), timeout: .seconds(10)) }
        done(try? InviteCode.make(server: server, user: member.user, seed: key.seed, until: until, person: member.person))
    }
}

#if DEBUG
/// Sample people for screenshots (DECKHAND_TEAM_DEMO=1); fictional names.
enum TeamDemo {
    static var entries: [Team.Entry] {
        let now = Date()
        func m(_ user: String, _ person: String, _ role: Team.Role, _ groups: [String] = [], _ days: Double) -> Team.Member {
            Team.Member(user: user, person: person, role: role, groups: groups, folders: role == .developer ? ["/srv/shop"] : [],
                        invited: now.addingTimeInterval(-days * 86_400), inviteUntil: now.addingTimeInterval(86_400))
        }
        return [
            Team.Entry(member: m("mara", "Mara Lindqvist", .admin, [], 40), exists: true, lastLogin: now.addingTimeInterval(-3 * 3600), pending: false),
            Team.Entry(member: m("jonas", "Jonas Weber", .developer, ["docker"], 12), exists: true, lastLogin: now.addingTimeInterval(-26 * 60), pending: false),
            Team.Entry(member: m("priya", "Priya Raman", .developer, ["docker"], 5), exists: true, lastLogin: now.addingTimeInterval(-2 * 86_400), pending: false),
            Team.Entry(member: m("sam", "Sam Okafor", .readOnly, [], 0.1), exists: true, lastLogin: nil, pending: true),
        ]
    }
}
#endif
