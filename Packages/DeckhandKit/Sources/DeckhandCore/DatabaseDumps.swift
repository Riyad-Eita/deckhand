import Foundation

/// Nightly dumps of Postgres, MySQL/MariaDB and SQLite databases — on the server itself (when the login user has
/// access) or inside Docker containers — with a retention, a push on failure, a test restore into a scratch
/// database, and a confirmed real restore. Dumps land in `~/.deckhand/db/dumps`, which the restic backups pick up.
public enum DatabaseDumps {
    static let dir = "$HOME/.deckhand/db"

    public enum Engine: String, Sendable, Hashable, Codable { case postgres, mysql, sqlite }

    public struct Database: Sendable, Hashable, Identifiable {
        public var engine: Engine
        /// `local`, `docker:<container>` or, for SQLite, the file path.
        public var location: String
        public var name: String
        public var id: String { "\(engine.rawValue)|\(location)|\(name)" }
        public var container: String? { location.hasPrefix("docker:") ? String(location.dropFirst(7)) : nil }
        public var label: String {
            switch engine {
            case .sqlite: (location as NSString).lastPathComponent
            default: container.map { "\(name) · \($0)" } ?? name
            }
        }
    }

    public struct Job: Sendable, Hashable, Identifiable {
        public var id: String
        public var database: Database
        public var keepDays: Int
        public var dumps: [Dump] = []
        public var lastRun: (date: Date, ok: Bool)?
        public static func == (a: Job, b: Job) -> Bool { a.id == b.id && a.dumps == b.dumps && a.keepDays == b.keepDays }
        public func hash(into h: inout Hasher) { h.combine(id) }
    }

    public struct Dump: Sendable, Hashable, Identifiable {
        public var id: String { file }
        public var file: String
        public var date: Date
        public var bytes: Int64
    }

    /// Lists databases the login user can dump. Lines: `@@db <engine>\t<location>\t<name>`.
    public static let discoverCommand = #"""
    if command -v psql >/dev/null 2>&1; then
      psql -d postgres -lqtA 2>/dev/null | cut -d'|' -f1 | grep -vE '^(template0|template1|postgres|)$' | while read -r d; do printf '@@db postgres\tlocal\t%s\n' "$d"; done
    fi
    if command -v mysql >/dev/null 2>&1; then
      mysql -N -e 'show databases' 2>/dev/null | grep -vE '^(information_schema|performance_schema|mysql|sys)$' | while read -r d; do printf '@@db mysql\tlocal\t%s\n' "$d"; done
    fi
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | while read -r c img; do
        case "$img" in
          *postgres*|*postgis*|*timescale*)
            docker exec "$c" sh -c 'psql -U "${POSTGRES_USER:-postgres}" -lqtA' 2>/dev/null | cut -d'|' -f1 | grep -vE '^(template0|template1|)$' | while read -r d; do printf '@@db postgres\tdocker:%s\t%s\n' "$c" "$d"; done ;;
          *mysql*|*mariadb*)
            docker exec "$c" sh -c 'mysql -uroot -p"${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" -N -e "show databases"' 2>/dev/null | grep -vE '^(information_schema|performance_schema|mysql|sys)$' | while read -r d; do printf '@@db mysql\tdocker:%s\t%s\n' "$c" "$d"; done ;;
        esac
      done
    fi
    find "$HOME" /srv /var/www /opt -maxdepth 4 -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) -size +0 -readable 2>/dev/null | grep -v '/.deckhand/' | head -n 30 | while read -r f; do
      head -c 16 "$f" 2>/dev/null | grep -q 'SQLite format 3' && printf '@@db sqlite\t%s\t%s\n' "$f" "$(basename "$f")"
    done
    true
    """#

    public static func parseDiscovery(_ out: String) -> [Database] {
        out.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("@@db ") else { return nil }
            let f = line.dropFirst(5).components(separatedBy: "\t")
            guard f.count == 3, let e = Engine(rawValue: f[0]) else { return nil }
            return Database(engine: e, location: f[1], name: f[2])
        }
    }

    /// The shell that writes one gzipped dump of `db` to stdout.
    static func dumpPipe(_ db: Database) -> String {
        let n = ShellQuote.quote(db.name)
        switch (db.engine, db.container) {
        case (.postgres, nil): return "pg_dump --clean --if-exists -d \(n) | gzip"
        case (.postgres, let c?): return "docker exec \(ShellQuote.quote(c)) sh -c 'pg_dump -U \"${POSTGRES_USER:-postgres}\" --clean --if-exists -d \"$1\"' sh \(n) | gzip"
        case (.mysql, nil): return "mysqldump --single-transaction --routines \(n) | gzip"
        case (.mysql, let c?): return "docker exec \(ShellQuote.quote(c)) sh -c 'mysqldump -uroot -p\"${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}\" --single-transaction --routines \"$1\"' sh \(n) | gzip"
        case (.sqlite, _):
            let f = ShellQuote.quote(db.location)
            return "{ if command -v sqlite3 >/dev/null 2>&1; then t=$(mktemp); sqlite3 \(f) \".backup '$t'\" && cat \"$t\"; rm -f \"$t\"; else cat \(f); fi; } | gzip"
        }
    }

    /// Restores the gzipped dump `file` into `target` (a database name; SQLite: a file path).
    static func restorePipe(_ db: Database, into target: String, file: String) -> String {
        let t = ShellQuote.quote(target), z = "gunzip -c \(ShellQuote.quote(file))"
        switch (db.engine, db.container) {
        case (.postgres, nil): return "\(z) | psql -q -v ON_ERROR_STOP=1 -d \(t) >/dev/null"
        case (.postgres, let c?): return "\(z) | docker exec -i \(ShellQuote.quote(c)) sh -c 'psql -q -v ON_ERROR_STOP=1 -U \"${POSTGRES_USER:-postgres}\" -d \"$1\"' sh \(t) >/dev/null"
        case (.mysql, nil): return "\(z) | mysql \(t)"
        case (.mysql, let c?): return "\(z) | docker exec -i \(ShellQuote.quote(c)) sh -c 'mysql -uroot -p\"${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}\" \"$1\"' sh \(t)"
        case (.sqlite, _): return "\(z) > \(t)"
        }
    }

    /// One line per job in jobs.tsv: id, engine, location, name, keep days.
    static func jobLine(_ id: String, _ db: Database, keepDays: Int) -> String {
        [id, db.engine.rawValue, db.location, db.name, String(keepDays)].map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t")
    }

    /// The nightly script, generated from the jobs (so each dump command is fixed, not built at run time).
    static func runScript(_ jobs: [(id: String, db: Database, keep: Int)], topic: String) -> String {
        let body = jobs.map { j in
            """
            mkdir -p "$O/\(j.id)"; f="$O/\(j.id)/$(date -u +%Y%m%d-%H%M%S).\(j.db.engine == .sqlite ? "sqlite" : "sql").gz"
            if ( set -o pipefail 2>/dev/null; \(dumpPipe(j.db)) ) > "$f.part" && [ -s "$f.part" ]; then mv "$f.part" "$f"; echo "$(date +%s) \(j.id) 1" >> "$D/runs"
            else rm -f "$f.part"; echo "$(date +%s) \(j.id) 0" >> "$D/runs"; fail="$fail \(j.db.label)"; fi
            find "$O/\(j.id)" -name '*.gz' -mtime +\(j.keep) -delete 2>/dev/null
            """
        }.joined(separator: "\n")
        return """
        #!/bin/bash
        # Deckhand database dumps — run by cron. Managed by the Deckhand app.
        D="$HOME/.deckhand/db"; O="$D/dumps"; fail=
        \(body)
        tail -n 500 "$D/runs" > "$D/runs.tmp" 2>/dev/null && mv "$D/runs.tmp" "$D/runs"
        T=\(ShellQuote.quote(topic))
        if [ -n "$fail" ] && [ -n "$T" ]; then curl -fsS -m 10 -H "Title: Database dump failed on $(hostname)" -H "Priority: high" -H "Tags: warning" -d "Failed:$fail" "$T" >/dev/null 2>&1; fi
        true
        """
    }

    /// Saves the jobs, writes the script, schedules it nightly and adds the dump folder to the restic backups if
    /// those are set up. Then runs once. Prints `@@ok`, `@@backups` (added to restic), `@@nocron`.
    public static func saveCommand(_ jobs: [(id: String, db: Database, keep: Int)], hour: Int, topic: String) -> String {
        let tsv = jobs.map { jobLine($0.id, $0.db, keepDays: $0.keep) }.joined(separator: "\n")
        return """
        D=\(dir); mkdir -p "$D/dumps" && chmod 700 "$D"
        printf '%s\\n' \(ShellQuote.quote(tsv)) > "$D/jobs.tsv"
        printf '%s\\n' \(ShellQuote.quote(runScript(jobs, topic: topic))) > "$D/run.sh" && chmod 700 "$D/run.sh"
        if [ -f "$HOME/.deckhand/backup/paths" ] && ! grep -qxF "$D/dumps" "$HOME/.deckhand/backup/paths"; then echo "$D/dumps" >> "$HOME/.deckhand/backup/paths"; echo '@@backups'; fi
        bash "$D/run.sh"
        if command -v crontab >/dev/null 2>&1; then
          { crontab -l 2>/dev/null | grep -v 'deckhand/db/run.sh'; \(jobs.isEmpty ? "" : "echo \"\(Int.random(in: 0...59)) \(max(0, min(23, hour))) * * * $HOME/.deckhand/db/run.sh >/dev/null 2>&1 # deckhand-db\";") } | crontab -
        else echo '@@nocron'; fi
        echo '@@ok'
        """
    }

    /// Jobs, their dumps and the last runs.
    public static let statusCommand = """
    D=\(dir); [ -f "$D/jobs.tsv" ] || exit 0
    crontab -l 2>/dev/null | grep 'deckhand/db/run.sh' | awk '{print "@@cron", $1, $2}'
    while IFS= read -r line; do [ -n "$line" ] || continue; echo "@@job $line"; id=$(printf '%s' "$line" | cut -f1)
      for f in "$D/dumps/$id"/*.gz; do [ -f "$f" ] && echo "@@dump $id $(stat -c '%s %Y' "$f" 2>/dev/null || stat -f '%z %m' "$f") $f"; done
    done < "$D/jobs.tsv"
    [ -f "$D/runs" ] && tail -n 50 "$D/runs" | sed 's/^/@@run /'
    true
    """

    public struct Status: Sendable, Hashable {
        public var jobs: [Job] = []
        public var schedule: (minute: Int, hour: Int)?
        public static func == (a: Status, b: Status) -> Bool { a.jobs == b.jobs }
        public func hash(into h: inout Hasher) { h.combine(jobs) }
    }

    public static func parseStatus(_ out: String) -> Status {
        var s = Status()
        var runs: [String: (Date, Bool)] = [:]
        for line in out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("@@cron ") {
                let p = line.dropFirst(7).split(separator: " ").compactMap { Int($0) }
                if p.count == 2 { s.schedule = (p[0], p[1]) }
            } else if line.hasPrefix("@@job ") {
                let f = line.dropFirst(6).components(separatedBy: "\t")
                guard f.count == 5, let e = Engine(rawValue: f[1]) else { continue }
                s.jobs.append(Job(id: f[0], database: Database(engine: e, location: f[2], name: f[3]), keepDays: Int(f[4]) ?? 7))
            } else if line.hasPrefix("@@dump ") {
                let p = line.dropFirst(7).split(separator: " ", maxSplits: 3).map(String.init)
                guard p.count == 4, let i = s.jobs.firstIndex(where: { $0.id == p[0] }), let b = Int64(p[1]), let t = Double(p[2]) else { continue }
                s.jobs[i].dumps.append(Dump(file: p[3], date: Date(timeIntervalSince1970: t), bytes: b))
            } else if line.hasPrefix("@@run ") {
                let p = line.dropFirst(6).split(separator: " ")
                if p.count == 3, let t = Double(p[0]) { runs[String(p[1])] = (Date(timeIntervalSince1970: t), p[2] == "1") }
            }
        }
        for i in s.jobs.indices {
            s.jobs[i].dumps.sort { $0.date > $1.date }
            if let r = runs[s.jobs[i].id] { s.jobs[i].lastRun = (r.0, r.1) }
        }
        return s
    }

    /// Loads a dump into a scratch database (or file), counts what came back, and removes it again.
    /// Prints `@@tables <n>` (SQLite: `@@integrity ok`) or `@@failed <why>`.
    public static func testRestoreCommand(_ db: Database, dump: String) -> String {
        let f = ShellQuote.quote(dump)
        let scratch = "\(db.name)_dh_test"
        switch db.engine {
        case .postgres:
            let exec = db.container.map { "docker exec -i \(ShellQuote.quote($0)) sh -c 'psql -U \"${POSTGRES_USER:-postgres}\" \"$@\"' sh" } ?? "psql"
            return """
            \(exec) -d postgres -qc \(ShellQuote.quote("DROP DATABASE IF EXISTS \"\(scratch)\"")) >/dev/null 2>&1
            \(exec) -d postgres -qc \(ShellQuote.quote("CREATE DATABASE \"\(scratch)\"")) >/dev/null || { echo '@@failed could not create a scratch database'; exit 0; }
            if \(restorePipe(db, into: scratch, file: dump)) 2>/tmp/dh-restore.err; then
              echo "@@tables $(\(exec) -d \(ShellQuote.quote(scratch)) -tAc "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')")"
            else echo "@@failed $(tail -n 1 /tmp/dh-restore.err)"; fi
            \(exec) -d postgres -qc \(ShellQuote.quote("DROP DATABASE IF EXISTS \"\(scratch)\"")) >/dev/null 2>&1; rm -f /tmp/dh-restore.err
            """
        case .mysql:
            let exec = db.container.map { "docker exec -i \(ShellQuote.quote($0)) sh -c 'mysql -uroot -p\"${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}\" \"$@\"' sh" } ?? "mysql"
            return """
            \(exec) -e \(ShellQuote.quote("DROP DATABASE IF EXISTS `\(scratch)`; CREATE DATABASE `\(scratch)`")) || { echo '@@failed could not create a scratch database'; exit 0; }
            if \(restorePipe(db, into: scratch, file: dump)) 2>/tmp/dh-restore.err; then
              echo "@@tables $(\(exec) -N -e \(ShellQuote.quote("select count(*) from information_schema.tables where table_schema='\(scratch)'")))"
            else echo "@@failed $(tail -n 1 /tmp/dh-restore.err)"; fi
            \(exec) -e \(ShellQuote.quote("DROP DATABASE IF EXISTS `\(scratch)`")); rm -f /tmp/dh-restore.err
            """
        case .sqlite:
            return """
            t=$(mktemp); gunzip -c \(f) > "$t"
            if command -v sqlite3 >/dev/null 2>&1; then r=$(sqlite3 "$t" 'PRAGMA integrity_check' 2>&1); [ "$r" = ok ] && echo "@@integrity ok" && echo "@@tables $(sqlite3 "$t" "select count(*) from sqlite_master where type='table'")" || echo "@@failed $r"
            else head -c 16 "$t" | grep -q 'SQLite format 3' && echo '@@integrity ok' || echo '@@failed not a SQLite file'; fi
            rm -f "$t"
            """
        }
    }

    /// Restores a dump over the live database. The app asks for the database name first. SQLite keeps the old
    /// file next to it as `.pre-restore`.
    public static func restoreCommand(_ db: Database, dump: String) -> String {
        let f = ShellQuote.quote(dump)
        if db.engine == .sqlite {
            let live = ShellQuote.quote(db.location)
            return "cp -p \(live) \(ShellQuote.quote(db.location + ".pre-restore")) && gunzip -c \(f) > \(live).dh && mv \(live).dh \(live) && echo '@@restored'"
        }
        return "if \(restorePipe(db, into: db.name, file: dump)) 2>/tmp/dh-restore.err; then echo '@@restored'; else echo \"@@failed $(tail -n 1 /tmp/dh-restore.err)\"; fi; rm -f /tmp/dh-restore.err"
    }

    public static func newJobID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
}
