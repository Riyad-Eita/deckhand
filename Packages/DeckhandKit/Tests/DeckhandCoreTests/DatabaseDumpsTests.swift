import Foundation
import Testing
@testable import DeckhandCore

struct DatabaseDumpsTests {
    @Test func discovery() {
        let dbs = DatabaseDumps.parseDiscovery("@@db postgres\tlocal\tshop\n@@db mysql\tdocker:db1\tblog\n@@db sqlite\t/srv/app/data.db\tdata.db\nnoise\n")
        #expect(dbs.map(\.label) == ["shop", "blog · db1", "data.db"])
        #expect(dbs[1].container == "db1" && dbs[0].container == nil)
    }

    @Test func pipes() {
        let pg = DatabaseDumps.Database(engine: .postgres, location: "docker:pg", name: "shop")
        #expect(DatabaseDumps.dumpPipe(pg).hasPrefix("docker exec 'pg' sh -c 'pg_dump -U \"${POSTGRES_USER:-postgres}\" --clean --if-exists -d \"$1\"' sh 'shop' | gzip"))
        let lite = DatabaseDumps.Database(engine: .sqlite, location: "/srv/a b.db", name: "a b.db")
        #expect(DatabaseDumps.dumpPipe(lite).contains("sqlite3 '/srv/a b.db'"))
        let script = DatabaseDumps.runScript([("j1", pg, 7)], topic: "https://ntfy.sh/x")
        #expect(script.contains("mkdir -p \"$O/j1\"") && script.contains("-mtime +7 -delete"))
        #expect(DatabaseDumps.restoreCommand(lite, dump: "/d/x.gz").contains("'/srv/a b.db.pre-restore'"))
    }

    @Test func status() {
        let out = """
        @@cron 12 2
        @@job j1\tpostgres\tlocal\tshop\t7
        @@dump j1 2048 1794390000 /home/me/.deckhand/db/dumps/j1/20261111-020000.sql.gz
        @@dump j1 1024 1794303600 /home/me/.deckhand/db/dumps/j1/20261110-020000.sql.gz
        @@run 1794390000 j1 1
        """
        let s = DatabaseDumps.parseStatus(out)
        #expect(s.schedule?.hour == 2 && s.jobs.count == 1)
        #expect(s.jobs[0].dumps.first?.bytes == 2048 && s.jobs[0].lastRun?.ok == true)
    }
}
