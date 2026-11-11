import Foundation
import Testing
@testable import DeckhandCore

struct DatabaseBrowserTests {
    let pg = DatabaseBrowser.Database(engine: .postgres, location: "local", name: "shop")
    let my = DatabaseBrowser.Database(engine: .mysql, location: "docker:db", name: "blog")

    @Test func csvWithQuotesNullsAndNewlines() {
        let g = DatabaseBrowser.parseCSV("id,name,note\n1,\"Smith, Ann\",\n2,\"\",\"line1\nline2 \"\"quoted\"\"\"\n")
        #expect(g.columns == ["id", "name", "note"])
        #expect(g.rows.count == 2)
        #expect(g.rows[0] == ["1", "Smith, Ann", nil])
        #expect(g.rows[1] == ["2", "", "line1\nline2 \"quoted\""])
    }

    @Test func tsvFromMySQL() {
        let g = DatabaseBrowser.parseTSV("id\ttitle\tbody\n1\tHello\tA\\tB\\nC\n2\tNULL\t\n")
        #expect(g.rows[0] == ["1", "Hello", "A\tB\nC"])
        #expect(g.rows[1] == ["2", nil, ""])
    }

    @Test func readOnlyWrapping() {
        #expect(DatabaseBrowser.wrap(pg, "select 1;", allowWrites: false) == "BEGIN READ ONLY;\nselect 1;\nROLLBACK;\n")
        #expect(DatabaseBrowser.wrap(my, "delete from x", allowWrites: true) == "delete from x;\n")
        let lite = DatabaseBrowser.Database(engine: .sqlite, location: "/srv/a.db", name: "a.db")
        #expect(DatabaseBrowser.sqlCommand(lite, "select 1").contains("-readonly '/srv/a.db'"))
    }

    @Test func sqlText() {
        #expect(DatabaseBrowser.ident(pg, "public.orders") == "\"public\".\"orders\"")
        #expect(DatabaseBrowser.ident(my, "or`ders") == "`or``ders`")
        #expect(DatabaseBrowser.rowsSQL(pg, table: "public.orders", filter: ("note", "it's"), limit: 50, offset: 100)
                == "select * from \"public\".\"orders\" where \"note\"::text ilike '%it''s%' limit 50 offset 100")
        #expect(DatabaseBrowser.updateSQL(pg, table: "public.orders", key: [("id", "7")], column: "total", newValue: "42")
                == "update \"public\".\"orders\" set \"total\" = '42' where \"id\" = '7'")
        #expect(DatabaseBrowser.updateSQL(pg, table: "t", key: [], column: "c", newValue: "x") == nil)
    }

    @Test func errorsAreReported() {
        if case .failure(let e) = DatabaseBrowser.parse(pg, "psql:<stdin>:2: ERROR:  relation \"nope\" does not exist\n") { #expect(e.message.contains("nope")) }
        else { Issue.record("expected an error") }
    }

    @Test func redis() {
        let keys = DatabaseBrowser.parseRedisKeys("@@key string\tsession:1\n@@key hash\tuser:7\n")
        #expect(keys.map(\.key) == ["session:1", "user:7"] && keys[1].type == "hash")
        #expect(DatabaseBrowser.redisValueCommand(.init(location: "docker:cache"), key: "user:7", type: "hash").contains("docker exec 'cache' redis-cli --raw hgetall 'user:7'"))
    }
}
