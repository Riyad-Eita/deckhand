import DeckhandCore
import DeckhandSSH
import SwiftData
import SwiftUI
import UIKit

/// SSH keys across all servers: rotate this iPhone's keys, and remove keys of lost devices everywhere.
struct KeysView: View {
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @Environment(Connections.self) private var connections
    @State private var results: [UUID: Outcome] = [:]
    @State private var rotating = false
    @State private var inventory: [UUID: [AuthorizedKeys.Entry]] = [:]
    @State private var loading = false
    @State private var confirmRemove: KeyGroup?
    @State private var confirmRotate = false

    enum Outcome: Equatable {
        case working
        case done(String)
        case skipped(String)
        case failed(String)
    }

    /// One key (by blob) and the servers it's on.
    struct KeyGroup: Identifiable, Hashable {
        let entry: AuthorizedKeys.Entry
        var servers: [String]
        var serverIDs: [UUID]
        var isThisIPhone: Bool
        var id: String { entry.blob }
    }

    private var keyServers: [Server] { servers.filter { $0.authKind == .key } }

    var body: some View {
        List {
            Section {
                ForEach(servers) { server in
                    HStack {
                        Text(server.displayName)
                        Spacer()
                        outcome(results[server.id], server: server)
                    }
                }
                Button {
                    confirmRotate = true
                } label: {
                    HStack {
                        Text(keyServers.count == 1 ? "Rotate the key on 1 server" : "Rotate keys on \(keyServers.count) servers")
                        Spacer()
                        if rotating { ProgressView() }
                    }
                }
                .disabled(rotating || keyServers.isEmpty)
                .accessibilityIdentifier("keys.rotate")
            } header: {
                Text("This iPhone's keys")
            } footer: {
                Text("Makes a new key for each server, installs it, logs in with it, and only then removes the old one. If anything fails, the old key stays.")
            }
            Section {
                if loading { HStack { ProgressView(); Text("Reading the servers…").foregroundStyle(.secondary) } }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(group.entry.comment.isEmpty ? String(localized: "No name") : group.entry.comment)
                            if group.isThisIPhone {
                                Text("this iPhone").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent.opacity(0.12), in: Capsule())
                            }
                        }
                        Text("\(group.entry.type) · \(String(group.entry.fingerprint.prefix(20)))…").font(Theme.monoSmall).foregroundStyle(.secondary)
                        Text("On \(group.servers.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        if !group.isThisIPhone {
                            Button("Remove everywhere") { confirmRemove = group }.tint(.red)
                        }
                    }
                }
            } header: {
                Text("Keys that can log in")
            } footer: {
                Text("Every key in authorized_keys on your servers, by name. Lost a device? Swipe its key to remove it from all servers at once. This iPhone's own keys can't be removed here.")
            }
        }
        .navigationTitle("SSH keys")
        .task { await loadInventory() }
        .refreshable { await loadInventory() }
        .confirmationDialog("Rotate keys now?", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("Rotate") { Task { await rotateAll() } }
        } message: {
            Text("Other apps or computers that use these exact keys from this iPhone stop working; your other devices keep their own keys.")
        }
        .confirmationDialog("Remove “\(confirmRemove?.entry.comment ?? "")” from \(confirmRemove?.servers.count ?? 0) servers?",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove everywhere", role: .destructive) { if let g = confirmRemove { Task { await remove(g) } } }
        } message: {
            Text("That key can't log in to these servers anymore. A backup of each authorized_keys file stays next to it.")
        }
    }

    @ViewBuilder private func outcome(_ o: Outcome?, server: Server) -> some View {
        switch o {
        case nil:
            Text(server.authKind == .key ? String(localized: "Key") : String(localized: "Password")).font(.caption).foregroundStyle(.secondary)
        case .working?: ProgressView().controlSize(.small)
        case .done(let s)?: Label(s, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .skipped(let s)?: Text(s).font(.caption).foregroundStyle(.secondary)
        case .failed(let s)?: Label(s, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private var groups: [KeyGroup] {
        var byBlob: [String: KeyGroup] = [:]
        for server in servers {
            let mine = currentBlob(server)
            for entry in inventory[server.id] ?? [] {
                var g = byBlob[entry.blob] ?? KeyGroup(entry: entry, servers: [], serverIDs: [], isThisIPhone: false)
                g.servers.append(server.displayName)
                g.serverIDs.append(server.id)
                if entry.blob == mine { g.isThisIPhone = true }
                byBlob[entry.blob] = g
            }
        }
        return byBlob.values.sorted { ($0.isThisIPhone ? 0 : 1, $0.entry.comment) < ($1.isThisIPhone ? 0 : 1, $1.entry.comment) }
    }

    private func currentBlob(_ server: Server) -> String? {
        guard server.authKind == .key, let key = Keychain.get(server.secretAccount),
              let line = SSHKeys.publicKeyLine(privateKey: key, comment: "x") else { return nil }
        return AuthorizedKeys.blob(ofPublicKey: line)
    }

    private func loadInventory() async {
        loading = true
        defer { loading = false }
        for server in servers {
            guard let conn = try? await connections.connection(for: server),
                  let r = try? await conn.run(AuthorizedKeys.listCommand, timeout: .seconds(20)) else { continue }
            inventory[server.id] = AuthorizedKeys.parse(r.stdout)
        }
    }

    private func rotateAll() async {
        rotating = true
        defer { rotating = false }
        for server in servers { results[server.id] = server.authKind == .key ? .working : .skipped(String(localized: "Uses a password")) }
        for server in keyServers { results[server.id] = await rotate(server) }
        await loadInventory()
    }

    private func rotate(_ server: Server) async -> Outcome {
        let old = currentBlob(server)
        let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "-")
        let pair = SSHKeys.generateEd25519(comment: "deckhand@\(device)")
        guard let newBlob = AuthorizedKeys.blob(ofPublicKey: pair.publicKey) else { return .failed("Couldn't make a key") }
        do {
            let conn = try await connections.connection(for: server)
            let installed = try await conn.run(KeyInstall.command(publicKey: pair.publicKey), timeout: .seconds(20))
            guard KeyInstall.succeeded(installed) else { return .failed(String(localized: "Couldn't install the new key")) }
            let fresh: SSHConnection
            do {
                fresh = try await connections.testLogin(server, port: server.port, credential: .privateKey(pair.privateKey, passphrase: nil))
            } catch {
                if let undo = AuthorizedKeys.removeCommand(blobs: [newBlob]) { _ = try? await conn.run(undo, timeout: .seconds(20)) }
                return .failed(String(localized: "The new key didn't work — the old one stays"))
            }
            Keychain.set(pair.privateKey, for: server.secretAccount)
            Keychain.set(nil, for: server.secretAccount + ".passphrase")
            if let old, old != newBlob, let remove = AuthorizedKeys.removeCommand(blobs: [old]) {
                _ = try? await fresh.run(remove, timeout: .seconds(20))
            }
            await connections.adopt(fresh, for: server, port: server.port)
            return .done(String(localized: "New key"))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func remove(_ group: KeyGroup) async {
        guard let cmd = AuthorizedKeys.removeCommand(blobs: [group.entry.blob]) else { return }
        for server in servers where group.serverIDs.contains(server.id) {
            // Never the key this iPhone uses for that server.
            guard currentBlob(server) != group.entry.blob, let conn = try? await connections.connection(for: server) else { continue }
            _ = try? await conn.run(cmd, timeout: .seconds(20))
        }
        await loadInventory()
    }
}
