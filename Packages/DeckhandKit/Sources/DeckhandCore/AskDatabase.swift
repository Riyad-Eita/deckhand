import Foundation

/// "How many users signed up this week?" — your model writes one read-only query from the database's schema, you see
/// it (and can edit it) before it runs, then get the result as a table and a one-sentence answer.
public enum AskDatabase {
    public typealias Database = DatabaseBrowser.Database

    /// Tables with their columns and types: rows of (table, column, type).
    public static func schemaSQL(_ db: Database) -> String {
        switch db.engine {
        case .postgres: """
            select table_schema || '.' || table_name as "table", column_name as "column", data_type as "type"
            from information_schema.columns where table_schema not in ('pg_catalog', 'information_schema')
            order by table_schema, table_name, ordinal_position
            """
        case .mysql: "select table_name as `table`, column_name as `column`, column_type as `type` from information_schema.columns where table_schema = database() order by table_name, ordinal_position"
        case .sqlite: "select m.name as \"table\", p.name as \"column\", p.type as \"type\" from sqlite_master m join pragma_table_info(m.name) p where m.type = 'table' and m.name not like 'sqlite_%' order by m.name, p.cid"
        }
    }

    /// `table(column type, …)` per line, at most `limit` characters (the biggest schemas are cut, not the prompt).
    public static func schemaText(_ grid: DatabaseBrowser.Grid, limit: Int = 12_000) -> String {
        var order: [String] = []
        var cols: [String: [String]] = [:]
        for row in grid.rows where row.count >= 3 {
            guard let t = row[0], let c = row[1] else { continue }
            if cols[t] == nil { order.append(t) }
            cols[t, default: []].append([c, row[2]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
        }
        var out = ""
        for t in order {
            let line = "\(t)(\(cols[t]!.joined(separator: ", ")))\n"
            if out.count + line.count > limit { out += "… (more tables)\n"; break }
            out += line
        }
        return out
    }

    static func dialect(_ db: Database) -> String {
        switch db.engine { case .postgres: "PostgreSQL"; case .mysql: "MySQL/MariaDB"; case .sqlite: "SQLite" }
    }

    public static func sqlSystem(_ db: Database) -> String {
        """
        You turn questions about a \(dialect(db)) database into one read-only SQL query. Use only the tables and \
        columns in the schema. Answer with the query in a ```sql block and nothing else. Only SELECT (or WITH … \
        SELECT). Add LIMIT 200 unless the question asks for a single value. Use the database's own date functions \
        for "today", "this week" and similar. If the schema can't answer the question, reply with one sentence \
        saying what's missing instead of a query.
        """
    }

    public static func sqlPrompt(question: String, schema: String) -> String {
        "Schema:\n\(schema)\nQuestion: \(question)"
    }

    /// The query in the reply's ```sql block (or the whole reply if it is a bare SELECT). Nil when there is none.
    public static func sql(in reply: String) -> String? {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: Substring
        if let open = t.range(of: "```sql") ?? t.range(of: "```") {
            let rest = t[open.upperBound...]
            body = rest.range(of: "```").map { rest[..<$0.lowerBound] } ?? rest
        } else {
            body = t[...]
        }
        let q = body.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isReadOnly(q) ? q : nil
    }

    /// One statement that only reads. (It runs in a read-only transaction anyway; this keeps the intent honest.)
    public static func isReadOnly(_ sql: String) -> Bool {
        let s = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["select", "with", "explain", "show", "pragma table_info", "values"].contains(where: { s.hasPrefix($0) }) else { return false }
        let code = s.replacingOccurrences(of: #"'([^']|'')*'"#, with: "''", options: .regularExpression)
        if code.trimmingCharacters(in: CharacterSet(charactersIn: "; \n")).contains(";") { return false }
        let words = Set(code.split(whereSeparator: { !$0.isLetter && $0 != "_" }).map(String.init))
        return words.isDisjoint(with: ["insert", "update", "delete", "drop", "alter", "create", "truncate", "grant", "revoke", "attach", "copy", "vacuum", "merge", "replace", "call", "do"])
    }

    public static let answerSystem = """
    Answer the user's question about their database in one or two short sentences, using only the query result \
    given. Name the number or the key rows. If the result is empty, say so plainly. No SQL, no Markdown tables.
    """

    public static func answerPrompt(question: String, sql: String, grid: DatabaseBrowser.Grid, maxRows: Int = 50) -> String {
        let head = grid.columns.joined(separator: ",")
        let rows = grid.rows.prefix(maxRows).map { $0.map { $0 ?? "NULL" }.joined(separator: ",") }.joined(separator: "\n")
        let more = grid.rows.count > maxRows ? "\n… \(grid.rows.count - maxRows) more rows" : ""
        return "Question: \(question)\nQuery: \(sql)\nResult (\(grid.rows.count) rows):\n\(head)\n\(rows)\(more)"
    }

    /// One model call without tools; the reply's text.
    public static func complete(_ provider: any LLMProvider, system: String, prompt: String, maxTokens: Int = 1_500) async throws -> String {
        var text = ""
        for try await event in provider.stream(ChatRequest(system: system, messages: [.user(prompt)], tools: [], maxTokens: maxTokens)) {
            if case .completed(let m, _, _) = event { text = m.text }
        }
        return text
    }
}
