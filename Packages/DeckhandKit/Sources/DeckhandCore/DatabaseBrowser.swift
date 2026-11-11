import Foundation

/// Look into Postgres, MySQL/MariaDB, SQLite and Redis through SSH — with the CLI tools on the server, so no database
/// port has to be open. Queries run read-only unless the user allows changes; a cell edit becomes an UPDATE by primary
/// key that the user confirms.
public enum DatabaseBrowser {
    public typealias Database = DatabaseDumps.Database

    public struct Grid: Sendable, Hashable {
        public var columns: [String]
        public var rows: [[String?]]
        public init(columns: [String] = [], rows: [[String?]] = []) { self.columns = columns; self.rows = rows }
    }

    // MARK: Running SQL

    static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    /// Shell that runs `sql` (sent base64-encoded) and prints CSV (MySQL: tab-separated, escaped).
    public static func sqlCommand(_ db: Database, _ sql: String, allowWrites: Bool = false) -> String {
        let n = ShellQuote.quote(db.name)
        let feed = "printf '%s' '\(b64(wrap(db, sql, allowWrites: allowWrites)))' | base64 -d | "
        switch (db.engine, db.container) {
        case (.postgres, nil): return feed + "psql -X -q -v ON_ERROR_STOP=1 --csv -d \(n) 2>&1"
        case (.postgres, let c?): return feed + "docker exec -i \(ShellQuote.quote(c)) sh -c 'psql -X -q -v ON_ERROR_STOP=1 --csv -U \"${POSTGRES_USER:-postgres}\" -d \"$1\"' sh \(n) 2>&1"
        case (.mysql, nil): return feed + "mysql -B \(n) 2>&1"
        case (.mysql, let c?): return feed + "docker exec -i \(ShellQuote.quote(c)) sh -c 'mysql -B -uroot -p\"${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}\" \"$1\"' sh \(n) 2>&1"
        case (.sqlite, _): return feed + "sqlite3 -csv -header \(allowWrites ? "" : "-readonly ")\(ShellQuote.quote(db.location)) 2>&1"
        }
    }

    static func wrap(_ db: Database, _ sql: String, allowWrites: Bool) -> String {
        let body = sql.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        guard !allowWrites else { return body + ";\n" }
        switch db.engine {
        case .postgres: return "BEGIN READ ONLY;\n\(body);\nROLLBACK;\n"
        case .mysql: return "SET SESSION TRANSACTION READ ONLY;\nSTART TRANSACTION;\n\(body);\nROLLBACK;\n"
        case .sqlite: return body + ";\n"
        }
    }

    /// Output of `sqlCommand` as a grid, or the error text.
    public static func parse(_ db: Database, _ out: String) -> Result<Grid, BrowserError> {
        let t = out.trimmingCharacters(in: .newlines)
        if let line = t.split(separator: "\n").first(where: { $0.hasPrefix("ERROR") || $0.hasPrefix("psql:") || $0.hasPrefix("Error") || $0.hasPrefix("Parse error") || $0.hasPrefix("Runtime error") }) {
            return .failure(BrowserError(message: String(line)))
        }
        return .success(db.engine == .mysql ? parseTSV(out) : parseCSV(out))
    }

    public struct BrowserError: Error, Sendable, Hashable {
        public var message: String
        public init(message: String) { self.message = message }
    }

    /// RFC 4180 CSV; an unquoted empty field is NULL (psql), a quoted empty one is "".
    public static func parseCSV(_ s: String) -> Grid {
        var records: [[String?]] = []
        var field = "", quoted = false, inQuotes = false, row: [String?] = []
        var chars = Array(s), i = 0
        if chars.last != "\n" { chars.append("\n") }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" { inQuotes = true; quoted = true }
            else if c == "," { row.append(field.isEmpty && !quoted ? nil : field); field = ""; quoted = false }
            else if c == "\n" || c == "\r\n" {
                row.append(field.isEmpty && !quoted ? nil : field); field = ""; quoted = false
                if !(row.count == 1 && row[0] == nil) { records.append(row) }
                row = []
            } else if c != "\r" { field.append(c) }
            i += 1
        }
        guard let header = records.first else { return Grid() }
        return Grid(columns: header.map { $0 ?? "" }, rows: Array(records.dropFirst()))
    }

    /// `mysql -B`: tabs between fields, `\t \n \\ \0` escaped, NULL as the word NULL.
    public static func parseTSV(_ s: String) -> Grid {
        func unescape(_ f: Substring) -> String? {
            if f == "NULL" { return nil }
            var out = "", esc = false
            for c in f {
                if esc { out.append(c == "t" ? "\t" : c == "n" ? "\n" : c == "0" ? "\0" : c); esc = false }
                else if c == "\\" { esc = true } else { out.append(c) }
            }
            return out
        }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        guard let head = lines.first else { return Grid() }
        return Grid(columns: head.split(separator: "\t", omittingEmptySubsequences: false).map(String.init),
                    rows: lines.dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(unescape) })
    }

    // MARK: SQL text

    public static func ident(_ db: Database, _ name: String) -> String {
        if db.engine == .mysql { return "`" + name.replacingOccurrences(of: "`", with: "``") + "`" }
        return name.split(separator: ".", maxSplits: 1).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ".")
    }

    public static func literal(_ v: String?) -> String {
        guard let v else { return "NULL" }
        return "'" + v.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public static func tablesSQL(_ db: Database) -> String {
        switch db.engine {
        case .postgres: """
            select t.table_schema || '.' || t.table_name as "table", greatest(coalesce(c.reltuples, 0), 0)::bigint as "rows"
            from information_schema.tables t
            left join pg_class c on c.oid = (quote_ident(t.table_schema) || '.' || quote_ident(t.table_name))::regclass
            where t.table_schema not in ('pg_catalog', 'information_schema') and t.table_type = 'BASE TABLE' order by 1
            """
        case .mysql: "select table_name as `table`, table_rows as `rows` from information_schema.tables where table_schema = database() and table_type = 'BASE TABLE' order by 1"
        case .sqlite: "select name as \"table\", '' as \"rows\" from sqlite_master where type = 'table' and name not like 'sqlite_%' order by 1"
        }
    }

    public static func primaryKeySQL(_ db: Database, table: String) -> String {
        switch db.engine {
        case .postgres: "select a.attname as \"column\" from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey) where i.indrelid = \(literal(ident(db, table)))::regclass and i.indisprimary"
        case .mysql: "select column_name as `column` from information_schema.key_column_usage where table_schema = database() and table_name = \(literal(table)) and constraint_name = 'PRIMARY' order by ordinal_position"
        case .sqlite: "select name as \"column\" from pragma_table_info(\(literal(table))) where pk > 0 order by pk"
        }
    }

    public static func rowsSQL(_ db: Database, table: String, filter: (column: String, text: String)? = nil, limit: Int = 50, offset: Int = 0) -> String {
        var sql = "select * from \(ident(db, table))"
        if let f = filter, !f.text.isEmpty {
            let col = ident(db, f.column), pattern = literal("%" + f.text + "%")
            switch db.engine {
            case .postgres: sql += " where \(col)::text ilike \(pattern)"
            case .mysql: sql += " where cast(\(col) as char) like \(pattern)"
            case .sqlite: sql += " where cast(\(col) as text) like \(pattern)"
            }
        }
        return sql + " limit \(max(1, limit)) offset \(max(0, offset))"
    }

    /// The UPDATE a cell edit becomes (shown to the user before it runs). Nil without a primary key.
    public static func updateSQL(_ db: Database, table: String, key: [(column: String, value: String?)], column: String, newValue: String?) -> String? {
        guard !key.isEmpty, !key.contains(where: { $0.value == nil }) else { return nil }
        let whereClause = key.map { "\(ident(db, $0.column)) = \(literal($0.value))" }.joined(separator: " and ")
        return "update \(ident(db, table)) set \(ident(db, column)) = \(literal(newValue)) where \(whereClause)"
    }

    // MARK: Redis

    public struct RedisTarget: Sendable, Hashable, Identifiable {
        /// `local` or `docker:<container>`.
        public var location: String
        public var id: String { location }
        public init(location: String) { self.location = location }
        public var label: String { location == "local" ? "Redis" : "Redis · " + location.dropFirst(7) }
        var cli: String {
            location.hasPrefix("docker:") ? "docker exec \(ShellQuote.quote(String(location.dropFirst(7)))) redis-cli" : "redis-cli"
        }
    }

    public static let redisDiscoverCommand = #"""
    command -v redis-cli >/dev/null 2>&1 && [ "$(redis-cli ping 2>/dev/null)" = PONG ] && echo '@@redis local'
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | while read -r c img; do case "$img" in *redis*|*valkey*) echo "@@redis docker:$c" ;; esac; done
    fi
    true
    """#

    public static func parseRedisDiscovery(_ out: String) -> [RedisTarget] {
        out.split(separator: "\n").filter { $0.hasPrefix("@@redis ") }.map { RedisTarget(location: String($0.dropFirst(8))) }
    }

    /// Keys matching a pattern with their types (`@@key <type>\t<key>`), at most 300.
    public static func redisKeysCommand(_ t: RedisTarget, pattern: String) -> String {
        let p = ShellQuote.quote(pattern.isEmpty ? "*" : pattern)
        return "\(t.cli) --scan --pattern \(p) 2>/dev/null | head -n 300 | while IFS= read -r k; do printf '@@key %s\\t%s\\n' \"$(\(t.cli) type \"$k\" < /dev/null)\" \"$k\"; done"
    }

    public static func parseRedisKeys(_ out: String) -> [(type: String, key: String)] {
        out.split(separator: "\n").compactMap { l in
            guard l.hasPrefix("@@key "), let tab = l.firstIndex(of: "\t") else { return nil }
            return (String(l[l.index(l.startIndex, offsetBy: 6)..<tab]), String(l[l.index(after: tab)...]))
        }
    }

    /// The value of one key, by type, plus its TTL on the first line (`@@ttl <seconds>`).
    public static func redisValueCommand(_ t: RedisTarget, key: String, type: String) -> String {
        let k = ShellQuote.quote(key)
        let get = switch type {
        case "string": "get \(k)"
        case "hash": "hgetall \(k)"
        case "list": "lrange \(k) 0 199"
        case "set": "srandmember \(k) 200"
        case "zset": "zrange \(k) 0 199 withscores"
        case "stream": "xrevrange \(k) + - count 50"
        default: "type \(k)"
        }
        return "echo \"@@ttl $(\(t.cli) ttl \(k))\"; \(t.cli) --raw \(get)"
    }
}
