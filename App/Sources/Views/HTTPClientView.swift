import DeckhandCore
import SwiftData
import SwiftUI
import UIKit

/// API requests from the phone or from a server's network: collections of requests, environments with
/// `{{variables}}`, and "Copy as cURL" commands pasted in.
struct HTTPCollectionsView: View {
    @State private var store = HTTPStore.shared
    @State private var naming = false
    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        List {
            if let message { Section { Text(message).font(.subheadline) } }
            if store.collections.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Send API requests").font(.headline)
                        Text("Group requests in collections, switch between environments like staging and production, and send them from this iPhone or from one of your servers — handy for APIs that only that server can reach.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Button { naming = true } label: { Label("New collection", systemImage: "folder.badge.plus") }
                    Button { pasteCurl() } label: { Label("Paste a curl command", systemImage: "doc.on.clipboard") }
                }
            } else {
                Section {
                    ForEach(store.collections) { c in
                        NavigationLink { HTTPCollectionView(collectionID: c.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.body.weight(.medium))
                                Text("\(c.requests.count) requests").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("http.collection.\(c.name)")
                    }
                    .onDelete { idx in for i in idx { store.delete(store.collections[i]) } }
                }
            }
        }
        .navigationTitle("HTTP requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { naming = true } label: { Label("New collection", systemImage: "folder.badge.plus") }
                    Button { pasteCurl() } label: { Label("Paste a curl command", systemImage: "doc.on.clipboard") }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add")
                .accessibilityIdentifier("http.add")
            }
        }
        .alert("New collection", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                store.collections.append(HTTPClient.Collection(name: name.isEmpty ? String(localized: "My API") : name,
                                                               environments: [HTTPClient.Environment(name: String(localized: "Default"))]))
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func pasteCurl() {
        guard let r = HTTPClient.importCurl(UIPasteboard.general.string ?? "") else {
            message = String(localized: "The clipboard doesn't hold a curl command. In a browser's developer tools, use Copy as cURL on a request.")
            return
        }
        if let i = store.collections.firstIndex(where: { $0.name == String(localized: "Imported") }) {
            store.collections[i].requests.append(r)
        } else {
            store.collections.append(HTTPClient.Collection(name: String(localized: "Imported"), requests: [r],
                                                           environments: [HTTPClient.Environment(name: String(localized: "Default"))]))
        }
        message = String(localized: "Added “\(r.name)” to Imported.")
    }
}

/// One collection: its requests and the active environment.
struct HTTPCollectionView: View {
    let collectionID: UUID
    @State private var store = HTTPStore.shared

    var body: some View {
        if let ci = store.index(of: collectionID) {
            let c = store.collections[ci]
            List {
                Section {
                    ForEach(c.requests) { r in
                        NavigationLink { HTTPRequestView(collectionID: collectionID, requestID: r.id) } label: { RequestRow(request: r) }
                            .accessibilityIdentifier("http.request.\(r.name)")
                    }
                    .onDelete { store.collections[ci].requests.remove(atOffsets: $0) }
                    .onMove { store.collections[ci].requests.move(fromOffsets: $0, toOffset: $1) }
                    Button {
                        store.collections[ci].requests.append(HTTPClient.Request(name: String(localized: "New request"), url: ""))
                    } label: { Label("New request", systemImage: "plus") }
                        .accessibilityIdentifier("http.newRequest")
                }
                Section {
                    Picker("Environment", selection: Binding(get: { c.activeEnvironment ?? c.environments.first?.id },
                                                             set: { store.collections[ci].activeEnvironment = $0 })) {
                        ForEach(c.environments) { e in Text(e.name).tag(Optional(e.id)) }
                    }
                    NavigationLink { HTTPEnvironmentsView(collectionID: collectionID) } label: {
                        Label("Variables", systemImage: "curlybraces")
                    }
                    .accessibilityIdentifier("http.environments")
                } footer: {
                    Text("Write {{name}} in a URL, header, body or token to use a variable of the chosen environment.")
                }
            }
            .navigationTitle(c.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
        }
    }
}

private struct RequestRow: View {
    let request: HTTPClient.Request
    var body: some View {
        HStack(spacing: 10) {
            MethodBadge(method: request.method)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.name).font(.body)
                if !request.url.isEmpty {
                    Text(request.url).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

private struct MethodBadge: View {
    let method: HTTPClient.Method
    var body: some View {
        Text(method.rawValue)
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(color)
            .frame(width: 52)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    private var color: Color {
        switch method {
        case .GET, .HEAD, .OPTIONS: .blue
        case .POST: .green
        case .PUT, .PATCH: .orange
        case .DELETE: .red
        }
    }
}

/// Edit and send one request; the response below.
struct HTTPRequestView: View {
    let collectionID: UUID
    let requestID: UUID
    @State private var store = HTTPStore.shared
    @Environment(Connections.self) private var connections
    @Query(sort: \Server.name) private var servers: [Server]
    @AppStorage("http.via") private var via = ""
    @State private var sending = false
    @State private var response: HTTPClient.Response?
    @State private var sentFrom = ""
    @State private var error: String?
    @State private var showHeaders = false
    @State private var task: Task<Void, Never>?

    private var indices: (Int, Int)? {
        guard let ci = store.index(of: collectionID), let ri = store.collections[ci].requests.firstIndex(where: { $0.id == requestID }) else { return nil }
        return (ci, ri)
    }

    var body: some View {
        if let (ci, ri) = indices {
            let binding = $store.collections[ci].requests[ri]
            let resolved = HTTPClient.resolve(binding.wrappedValue, variables: store.variables(of: store.collections[ci]))
            Form {
                Section {
                    TextField("Name", text: binding.name).font(.headline)
                    HStack {
                        Picker("Method", selection: binding.method) {
                            ForEach(HTTPClient.Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .accessibilityIdentifier("http.method")
                        TextField("https://api.example.com/items", text: binding.url, axis: .vertical)
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityIdentifier("http.url")
                    }
                    if !resolved.missing.isEmpty {
                        Label(String(localized: "Not set in this environment: \(resolved.missing.joined(separator: ", "))"), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Headers") {
                    ForEach(binding.headers) { $h in
                        HStack {
                            TextField("Name", text: $h.name).font(.callout.monospaced()).frame(maxWidth: 130)
                            TextField("Value", text: $h.value).font(.callout.monospaced())
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .opacity(h.enabled ? 1 : 0.4)
                        .swipeActions {
                            Button(String(localized: "Delete"), role: .destructive) { binding.wrappedValue.headers.removeAll { $0.id == h.id } }
                            Button(h.enabled ? String(localized: "Turn off") : String(localized: "Turn on")) { h.enabled.toggle() }.tint(.gray)
                        }
                    }
                    Button { binding.wrappedValue.headers.append(.init(name: "", value: "")) } label: { Label("Add header", systemImage: "plus") }
                }
                AuthSection(auth: binding.auth)
                if binding.wrappedValue.method != .GET && binding.wrappedValue.method != .HEAD {
                    Section("Body") {
                        TextEditor(text: binding.body)
                            .font(.callout.monospaced())
                            .frame(minHeight: 110)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("http.body")
                    }
                }
                Section {
                    Picker("Send from", selection: $via) {
                        Text("This iPhone").tag("")
                        ForEach(servers) { s in Text(s.displayName).tag(s.id.uuidString) }
                    }
                    .accessibilityIdentifier("http.via")
                    Button {
                        if sending { task?.cancel() } else { send(resolved) }
                    } label: {
                        HStack {
                            Label(sending ? String(localized: "Cancel") : String(localized: "Send"), systemImage: sending ? "xmark" : "paperplane.fill")
                                .font(.headline)
                            Spacer()
                            if sending { ProgressView() }
                        }
                    }
                    .disabled(resolved.url.isEmpty)
                    .accessibilityIdentifier("http.send")
                } footer: {
                    if !via.isEmpty { Text("Sent with curl on the server, so it reaches addresses only that server can see (localhost, private networks).") }
                }
                if let error { Section { ProblemView(message: error, compact: true) } }
                if let response { ResponseSection(response: response, sentFrom: sentFrom, showHeaders: $showHeaders) }
            }
            .navigationTitle(binding.wrappedValue.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = HTTPClient.curlCommand(resolved).components(separatedBy: "\n").last
                    } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copy as curl")
                }
            }
        }
    }

    private func send(_ r: HTTPClient.Resolved) {
        error = nil; response = nil; sending = true
        let server = servers.first { $0.id.uuidString == via }
        task = Task {
            defer { sending = false }
            do {
                if let server {
                    let conn = try await connections.connection(for: server)
                    response = try await HTTPStore.sendFromServer(r, conn: conn)
                    sentFrom = server.displayName
                } else {
                    response = try await HTTPStore.sendFromPhone(r)
                    sentFrom = String(localized: "this iPhone")
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct AuthSection: View {
    @Binding var auth: HTTPClient.Auth

    private enum Kind: String, CaseIterable { case none, bearer, basic, header }
    private var kind: Kind {
        switch auth { case .none: .none; case .bearer: .bearer; case .basic: .basic; case .header: .header }
    }

    var body: some View {
        Section("Auth") {
            Picker("Auth", selection: Binding(get: { kind }, set: { k in
                switch k {
                case .none: auth = .none
                case .bearer: auth = .bearer("")
                case .basic: auth = .basic(user: "", password: "")
                case .header: auth = .header(name: "X-API-Key", value: "")
                }
            })) {
                Text("None").tag(Kind.none)
                Text("Bearer token").tag(Kind.bearer)
                Text("User and password").tag(Kind.basic)
                Text("API key header").tag(Kind.header)
            }
            Group {
                switch auth {
                case .none: EmptyView()
                case .bearer(let token):
                    SecretField(prompt: "Token or {{token}}", text: Binding(get: { token }, set: { auth = .bearer($0) }))
                case .basic(let user, let password):
                    TextField("User", text: Binding(get: { user }, set: { auth = .basic(user: $0, password: password) }))
                    SecretField(prompt: "Password", text: Binding(get: { password }, set: { auth = .basic(user: user, password: $0) }))
                case .header(let name, let value):
                    TextField("Header", text: Binding(get: { name }, set: { auth = .header(name: $0, value: value) }))
                    SecretField(prompt: "Key or {{key}}", text: Binding(get: { value }, set: { auth = .header(name: name, value: $0) }))
                }
            }
            .font(.callout.monospaced())
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
}

/// Hidden like a password, unless it only names a variable (`{{token}}`), which is fine to show.
private struct SecretField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    private var isReference: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("{{") && t.hasSuffix("}}") && t.count > 4
    }
    var body: some View {
        if isReference { TextField(prompt, text: $text) } else { SecureField(prompt, text: $text) }
    }
}

private struct ResponseSection: View {
    let response: HTTPClient.Response
    let sentFrom: String
    @Binding var showHeaders: Bool

    private var color: Color {
        switch response.status {
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .orange
        default: .red
        }
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Text("\(response.status)")
                    .font(.headline.monospacedDigit()).foregroundStyle(color)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(color.opacity(0.14), in: Capsule())
                    .accessibilityIdentifier("http.status")
                VStack(alignment: .leading, spacing: 1) {
                    Text(response.reason).font(.subheadline).lineLimit(1)
                    Text("via \(sentFrom)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("http.sentFrom")
                }
                Spacer()
                Text("\(Int((response.seconds * 1000).rounded())) ms · \(ByteCountFormatter.string(fromByteCount: Int64(response.bytes), countStyle: .file))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            DisclosureGroup(String(localized: "Headers (\(response.headers.count))"), isExpanded: $showHeaders) {
                ForEach(response.headers.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(k).font(.caption.weight(.semibold).monospaced()).foregroundStyle(.secondary)
                        Text(v).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if !response.body.isEmpty {
                ScrollView(.horizontal) {
                    Text(String(response.prettyBody.prefix(60_000)))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, 4)
                }
                .accessibilityIdentifier("http.responseBody")
            }
        } header: {
            HStack {
                Text("Response")
                Spacer()
                Button { UIPasteboard.general.string = response.prettyBody } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .font(.caption).textCase(nil)
            }
        }
    }
}

/// Environments of a collection and their variables; secret values go to the Keychain.
struct HTTPEnvironmentsView: View {
    let collectionID: UUID
    @State private var store = HTTPStore.shared

    var body: some View {
        if let ci = store.index(of: collectionID) {
            List {
                ForEach($store.collections[ci].environments) { $env in
                    Section {
                        TextField("Environment name", text: $env.name).font(.headline)
                        ForEach($env.variables) { $v in
                            VariableRow(variable: $v)
                                .swipeActions {
                                    Button(String(localized: "Delete"), role: .destructive) {
                                        if v.secret { store.setSecret("", for: v) }
                                        env.variables.removeAll { $0.id == v.id }
                                    }
                                    Button(v.secret ? String(localized: "Not secret") : String(localized: "Secret")) {
                                        if v.secret { v.value = store.secret(v); store.setSecret("", for: v) } else { store.setSecret(v.value, for: v); v.value = "" }
                                        v.secret.toggle()
                                    }
                                    .tint(.gray)
                                }
                        }
                        Button { env.variables.append(.init(name: "", value: "")) } label: { Label("Add variable", systemImage: "plus") }
                    }
                }
                Section {
                    Button {
                        store.collections[ci].environments.append(.init(name: String(localized: "Environment \(store.collections[ci].environments.count + 1)")))
                    } label: { Label("New environment", systemImage: "square.stack.3d.up") }
                } footer: {
                    Text("Swipe a variable to mark it secret: its value then lives in this iPhone's Keychain, not in the saved collection.")
                }
            }
            .navigationTitle("Variables")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct VariableRow: View {
    @Binding var variable: HTTPClient.Variable
    @State private var secretValue = ""
    private var store: HTTPStore { .shared }

    var body: some View {
        HStack {
            TextField("name", text: $variable.name).font(.callout.monospaced()).frame(maxWidth: 120)
            if variable.secret {
                SecureField("value", text: $secretValue).font(.callout.monospaced())
                    .onAppear { secretValue = store.secret(variable) }
                    .onChange(of: secretValue) { _, v in store.setSecret(v, for: variable) }
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("value", text: $variable.value).font(.callout.monospaced())
            }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
    }
}
