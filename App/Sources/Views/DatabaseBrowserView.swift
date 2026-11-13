import DeckhandCore
import SwiftUI

/// Databases on the server, browsed over SSH: tables, rows, filters, SQL (read-only unless allowed), Redis keys.
struct DatabaseBrowserView: View {
    let server: Server
    @Environment(Connections.self) private var connections
    @State private var dbs: [DatabaseBrowser.Database]?
    @State private var redis: [DatabaseBrowser.RedisTarget] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let dbs {
                Section {
                    if dbs.isEmpty && redis.isEmpty {
                        Text("No databases found that your login user can reach. Postgres needs a role for this user, MySQL a ~/.my.cnf; Docker containers need access to Docker.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(dbs) { db in
                        NavigationLink { TablesView(server: server, db: db) } label: {
                            Label { VStack(alignment: .leading) { Text(db.label); Text(kind(db)).font(.caption).foregroundStyle(.secondary) } }
                                icon: { Image(systemName: "cylinder.split.1x2").foregroundStyle(Theme.accent) }
                        }
                        .accessibilityIdentifier("dbb.\(db.name)")
                    }
                    ForEach(redis) { r in
                        NavigationLink { RedisView(server: server, target: r) } label: {
                            Label(r.label, systemImage: "bolt.horizontal.fill")
                        }
                        .accessibilityIdentifier("dbb.redis")
                    }
                } footer: {
                    Text("Through SSH with the database tools on the server — no database port has to be open.")
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Databases")
        .task { await load() }
        .refreshable { await load() }
    }

    private func kind(_ db: DatabaseBrowser.Database) -> String {
        let e = switch db.engine { case .postgres: "PostgreSQL"; case .mysql: "MySQL / MariaDB"; case .sqlite: "SQLite" }
        return db.container.map { "\(e) · Docker \($0)" } ?? (db.engine == .sqlite ? db.location : e)
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            dbs = DatabaseDumps.parseDiscovery(try await conn.run(DatabaseDumps.discoverCommand, timeout: .seconds(90)).stdout)
            redis = DatabaseBrowser.parseRedisDiscovery(try await conn.run(DatabaseBrowser.redisDiscoverCommand, timeout: .seconds(30)).stdout)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// Runs SQL on the server and returns a grid or an error.
@MainActor
private func runSQL(_ connections: Connections, _ server: Server, _ db: DatabaseBrowser.Database, _ sql: String, writes: Bool = false) async -> Result<DatabaseBrowser.Grid, DatabaseBrowser.BrowserError> {
    do {
        let conn = try await connections.connection(for: server)
        return DatabaseBrowser.parse(db, try await conn.run(DatabaseBrowser.sqlCommand(db, sql, allowWrites: writes), timeout: .seconds(120)).stdout)
    } catch {
        return .failure(.init(message: error.localizedDescription))
    }
}

private struct TablesView: View {
    let server: Server
    let db: DatabaseBrowser.Database
    @Environment(Connections.self) private var connections
    @State private var tables: DatabaseBrowser.Grid?
    @State private var error: String?

    var body: some View {
        List {
            if let error { ProblemView(message: error, compact: true) }
            if let tables, !tables.rows.isEmpty {
                Section {
                    NavigationLink { AskDatabaseView(server: server, db: db) } label: {
                        Label("Ask in plain language", systemImage: "text.bubble")
                    }
                    .accessibilityIdentifier("dbb.ask")
                }
            }
            if let tables {
                if tables.rows.isEmpty { Text("No tables.").foregroundStyle(.secondary) }
                ForEach(Array(tables.rows.enumerated()), id: \.offset) { _, row in
                    if let name = row.first ?? nil {
                        NavigationLink { TableView(server: server, db: db, table: name) } label: {
                            HStack {
                                Text(name).font(.callout.monospaced())
                                Spacer()
                                if row.count > 1, let n = row[1], !n.isEmpty, let v = Int(n) { Text("~\(v)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .accessibilityIdentifier("table.\(name)")
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .navigationTitle(db.label)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { QueryView(server: server, db: db) } label: { Label("SQL", systemImage: "terminal") }
                    .accessibilityIdentifier("dbb.sql")
            }
        }
        .task {
            switch await runSQL(connections, server, db, DatabaseBrowser.tablesSQL(db)) {
            case .success(let g): tables = g
            case .failure(let e): error = e.message
            }
        }
    }
}

/// Rows of one table, 50 at a time, with a filter and cell edits by primary key.
private struct TableView: View {
    let server: Server
    let db: DatabaseBrowser.Database
    let table: String
    @Environment(Connections.self) private var connections
    @State private var grid: DatabaseBrowser.Grid?
    @State private var key: [String] = []
    @State private var page = 0
    @State private var filterColumn = ""
    @State private var filterText = ""
    @State private var error: String?
    @State private var editing: Edit?

    struct Edit: Identifiable { let row: [String?]; let column: Int; var id: String { "\(row)\(column)" } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Column", selection: $filterColumn) {
                    Text("Filter by").tag("")
                    ForEach(grid?.columns ?? [], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                TextField("contains …", text: $filterText).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { page = 0; Task { await load() } }
                    .disabled(filterColumn.isEmpty)
                    .accessibilityIdentifier("table.filter")
            }
            .padding(.horizontal).padding(.vertical, 8)
            if let error { ProblemView(message: error, compact: true).padding(.horizontal) }
            if let grid {
                GridView(grid: grid) { row, col in
                    if !key.isEmpty { editing = Edit(row: row, column: col) }
                }
            } else if error == nil { Spacer(); ProgressView(); Spacer() }
            HStack {
                Button { page -= 1; Task { await load() } } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                Spacer()
                Text("Rows \(page * 50 + 1)–\(page * 50 + (grid?.rows.count ?? 0))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { page += 1; Task { await load() } } label: { Image(systemName: "chevron.right") }.disabled((grid?.rows.count ?? 0) < 50)
            }
            .padding()
        }
        .navigationTitle(table)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if case .success(let g) = await runSQL(connections, server, db, DatabaseBrowser.primaryKeySQL(db, table: table)) { key = g.rows.compactMap { $0.first ?? nil } }
            await load()
        }
        .sheet(item: $editing) { e in
            EditCellSheet(server: server, db: db, table: table, columns: grid?.columns ?? [], key: key, edit: e) { Task { await load() } }
        }
    }

    private func load() async {
        let filter = filterColumn.isEmpty ? nil : (column: filterColumn, text: filterText)
        switch await runSQL(connections, server, db, DatabaseBrowser.rowsSQL(db, table: table, filter: filter, limit: 50, offset: page * 50)) {
        case .success(let g):
            grid = g; error = nil
        case .failure(let e): error = e.message
        }
    }
}

/// A scrollable table: header row, cells; NULL shown dimmed.
private struct GridView: View {
    let grid: DatabaseBrowser.Grid
    let tap: ([String?], Int) -> Void

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(grid.rows.enumerated()), id: \.offset) { i, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { c, v in
                                Text(v.map { $0.replacingOccurrences(of: "\n", with: "⏎") } ?? "NULL")
                                    .font(.caption.monospaced()).lineLimit(1)
                                    .foregroundStyle(v == nil ? .tertiary : .primary)
                                    .frame(width: 150, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                    .onTapGesture { tap(row, c) }
                            }
                        }
                        .background(i % 2 == 0 ? Color.clear : Color.primary.opacity(0.03))
                        .accessibilityIdentifier("row")
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(grid.columns, id: \.self) { c in
                            Text(c).font(.caption.weight(.semibold)).lineLimit(1)
                                .frame(width: 150, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 8)
                        }
                    }
                    .background(.bar)
                }
            }
        }
    }
}

private struct EditCellSheet: View {
    let server: Server
    let db: DatabaseBrowser.Database
    let table: String
    let columns: [String]
    let key: [String]
    let edit: TableView.Edit
    let saved: () -> Void
    @Environment(Connections.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var null = false
    @State private var confirming = false
    @State private var error: String?

    private var column: String { columns.indices.contains(edit.column) ? columns[edit.column] : "" }
    private var sql: String? {
        let k = key.compactMap { name in columns.firstIndex(of: name).map { (column: name, value: edit.row[$0]) } }
        return DatabaseBrowser.updateSQL(db, table: table, key: k, column: column, newValue: null ? nil : value)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { ProblemView(message: error, compact: true) }
                Section(column) {
                    TextField("Value", text: $value, axis: .vertical).font(.callout.monospaced()).disabled(null)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("cell.value")
                    Toggle("NULL", isOn: $null)
                }
                if let sql {
                    Section("This runs") { Text(sql).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            .navigationTitle("Edit value")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { confirming = true }.disabled(sql == nil).accessibilityIdentifier("cell.save")
                }
            }
            .confirmationDialog("Change this value in the live database?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Change it", role: .destructive) { Task { await save() } }
            }
            .onAppear {
                let v = edit.row.indices.contains(edit.column) ? edit.row[edit.column] : nil
                value = v ?? ""; null = v == nil
            }
        }
    }

    private func save() async {
        guard let sql else { return }
        switch await runSQL(connections, server, db, sql, writes: true) {
        case .success: saved(); dismiss()
        case .failure(let e): error = e.message
        }
    }
}

private struct QueryView: View {
    let server: Server
    let db: DatabaseBrowser.Database
    @Environment(Connections.self) private var connections
    @State private var sql = ""
    @State private var allowWrites = false
    @State private var askWrites = false
    @State private var result: DatabaseBrowser.Grid?
    @State private var error: String?
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $sql).font(.callout.monospaced()).frame(height: 140).padding(8)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .overlay(alignment: .topLeading) { if sql.isEmpty { Text("select * from …").font(.callout.monospaced()).foregroundStyle(.tertiary).padding(16).allowsHitTesting(false) } }
                .accessibilityIdentifier("sql.editor")
            HStack {
                Toggle("Allow changes", isOn: Binding(get: { allowWrites }, set: { if $0 { askWrites = true } else { allowWrites = false } }))
                    .font(.footnote).fixedSize()
                Spacer()
                Button { Task { await run() } } label: { if running { ProgressView() } else { Label("Run", systemImage: "play.fill") } }
                    .buttonStyle(.borderedProminent).disabled(sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || running)
                    .accessibilityIdentifier("sql.run")
            }
            .padding(.horizontal)
            Divider().padding(.top, 8)
            if let error { ProblemView(message: error, compact: true).padding() }
            if let result {
                if result.columns.isEmpty { Text(allowWrites ? "Done." : "No rows.").foregroundStyle(.secondary).padding() }
                else { GridView(grid: result) { _, _ in } }
            }
            Spacer(minLength: 0)
        }
        .navigationTitle("SQL")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Allow changes?", isPresented: $askWrites) {
            Button("Allow", role: .destructive) { allowWrites = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Queries then run for real against \(db.label). Without this they run in a read-only transaction.")
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        switch await runSQL(connections, server, db, sql, writes: allowWrites) {
        case .success(let g): result = g; error = nil
        case .failure(let e): error = e.message; result = nil
        }
    }
}

private struct RedisView: View {
    let server: Server
    let target: DatabaseBrowser.RedisTarget
    @Environment(Connections.self) private var connections
    @State private var pattern = "*"
    @State private var keys: [(type: String, key: String)] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("Pattern, e.g. session:*", text: $pattern).font(.callout.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await load() } }
            }
            if let error { ProblemView(message: error, compact: true) }
            Section {
                if keys.isEmpty { Text("No keys.").foregroundStyle(.secondary) }
                ForEach(keys, id: \.key) { k in
                    NavigationLink { RedisValueView(server: server, target: target, key: k.key, type: k.type) } label: {
                        HStack {
                            Text(k.key).font(.callout.monospaced()).lineLimit(1)
                            Spacer()
                            Text(k.type).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                    }
                    .accessibilityIdentifier("redis.key")
                }
            } footer: { Text("Up to 300 keys.") }
        }
        .navigationTitle(target.label)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let conn = try await connections.connection(for: server)
            keys = DatabaseBrowser.parseRedisKeys(try await conn.run(DatabaseBrowser.redisKeysCommand(target, pattern: pattern), timeout: .seconds(60)).stdout)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct RedisValueView: View {
    let server: Server
    let target: DatabaseBrowser.RedisTarget
    let key: String
    let type: String
    @Environment(Connections.self) private var connections
    @State private var ttl: String?
    @State private var value: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Type", value: type)
                if let ttl { LabeledContent("Expires", value: ttl == "-1" ? String(localized: "never") : String(localized: "in \(ttl) s")) }
            }
            Section("Value") {
                if let value { Text(value).font(.caption.monospaced()).textSelection(.enabled) } else { ProgressView() }
            }
        }
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let conn = try? await connections.connection(for: server),
                  let out = try? await conn.run(DatabaseBrowser.redisValueCommand(target, key: key, type: type), timeout: .seconds(30)).stdout else { return }
            var lines = out.components(separatedBy: "\n")
            if let first = lines.first, first.hasPrefix("@@ttl ") { ttl = String(first.dropFirst(6)); lines.removeFirst() }
            value = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
    }
}

/// A question in plain language → your model writes one read-only query → you see it (and can change it) → it runs
/// read-only → table and a short answer.
private struct AskDatabaseView: View {
    let server: Server
    let db: DatabaseBrowser.Database
    @Environment(Connections.self) private var connections
    @Environment(AppSettings.self) private var settings
    @State private var question = ""
    @State private var sql = ""
    @State private var result: DatabaseBrowser.Grid?
    @State private var answer: String?
    @State private var note: String?
    @State private var error: String?
    @State private var busy: String?
    @FocusState private var focused: Bool

    var body: some View {
        List {
            Section {
                TextField("How many orders came in this week?", text: $question, axis: .vertical)
                    .lineLimit(1...4).focused($focused)
                    .accessibilityIdentifier("ask.question")
                Button { Task { await write() } } label: {
                    HStack { Label("Write the query", systemImage: "sparkles"); Spacer(); if busy == "write" { ProgressView() } }
                }
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || busy != nil)
                .accessibilityIdentifier("ask.write")
            } footer: {
                if !settings.isConfigured {
                    Text("Needs a model key in Settings. Your model sees the table and column names, not the data — until you run the query and ask for the answer.")
                } else {
                    Text("Your model sees the table and column names to write the query; the result goes to it only for the short answer.")
                }
            }
            if let error { ProblemView(message: error, compact: true) }
            if let note { Section { Text(note).font(.subheadline) } }
            if !sql.isEmpty {
                Section {
                    TextEditor(text: $sql).font(.callout.monospaced()).frame(minHeight: 90)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("ask.sql")
                    Button { Task { await run() } } label: {
                        HStack { Label("Run read-only", systemImage: "play.fill"); Spacer(); if busy == "run" { ProgressView() } }
                    }
                    .disabled(busy != nil || !AskDatabase.isReadOnly(sql))
                    .accessibilityIdentifier("ask.run")
                } header: {
                    Text("Query")
                } footer: {
                    if !AskDatabase.isReadOnly(sql) { Text("Only single reading queries run here. Use SQL with “Allow changes” for anything else.").foregroundStyle(.orange) }
                    else { Text("Check it, change it if you like — it runs in a read-only transaction.") }
                }
            }
            if let answer {
                Section { Text(answer).font(.body.weight(.medium)).accessibilityIdentifier("ask.answer") }
            }
            if let result {
                Section("\(result.rows.count) rows") {
                    if result.columns.isEmpty { Text("No rows.").foregroundStyle(.secondary) }
                    else { GridView(grid: result) { _, _ in }.frame(minHeight: 160).listRowInsets(EdgeInsets()) }
                }
            }
        }
        .navigationTitle("Ask")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = question.isEmpty }
    }

    private var provider: (any LLMProvider)? { settings.isConfigured ? AppProviders.make(settings.providerConfig) : nil }

    private func write() async {
        focused = false
        busy = "write"
        defer { busy = nil }
        error = nil; note = nil; answer = nil; result = nil
        #if DEBUG
        if let canned = ProcessInfo.processInfo.environment["DECKHAND_SEED_ASK_SQL"] { sql = canned; return }
        #endif
        guard let provider else { error = LLMError.missingAPIKey.localizedDescription; return }
        let schema: DatabaseBrowser.Grid
        switch await runSQL(connections, server, db, AskDatabase.schemaSQL(db)) {
        case .success(let g): schema = g
        case .failure(let e): error = e.message; return
        }
        do {
            let reply = try await AskDatabase.complete(provider, system: AskDatabase.sqlSystem(db),
                                                       prompt: AskDatabase.sqlPrompt(question: question, schema: AskDatabase.schemaText(schema)))
            if let q = AskDatabase.sql(in: reply) { sql = q } else { sql = ""; note = reply.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch { self.error = error.localizedDescription }
    }

    private func run() async {
        focused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        busy = "run"
        defer { busy = nil }
        error = nil; answer = nil
        switch await runSQL(connections, server, db, sql) {
        case .success(let g): result = g
        case .failure(let e): error = e.message; result = nil; return
        }
        guard let provider, let result else { return }
        answer = try? await AskDatabase.complete(provider, system: AskDatabase.answerSystem,
                                                 prompt: AskDatabase.answerPrompt(question: question, sql: sql, grid: result), maxTokens: 300)
    }
}
