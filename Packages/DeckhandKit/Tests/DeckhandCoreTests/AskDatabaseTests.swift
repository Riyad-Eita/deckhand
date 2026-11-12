import Foundation
import Testing
@testable import DeckhandCore

struct AskDatabaseTests {
    let pg = AskDatabase.Database(engine: .postgres, location: "local", name: "shop")

    @Test func schemaBecomesCompactText() {
        let g = DatabaseBrowser.Grid(columns: ["table", "column", "type"], rows: [
            ["public.orders", "id", "integer"], ["public.orders", "total", "numeric"], ["public.customers", "email", "text"],
        ])
        #expect(AskDatabase.schemaText(g) == "public.orders(id integer, total numeric)\npublic.customers(email text)\n")
        #expect(AskDatabase.schemaText(g, limit: 50).hasSuffix("… (more tables)\n"))
    }

    @Test func onlySingleReadingStatementsPass() {
        #expect(AskDatabase.sql(in: "```sql\nselect count(*) from orders;\n```") == "select count(*) from orders")
        #expect(AskDatabase.sql(in: "SELECT 1") == "SELECT 1")
        #expect(AskDatabase.sql(in: "```sql\nwith w as (select 1) select * from w\n```") != nil)
        #expect(AskDatabase.sql(in: "The schema has no signup date.") == nil)
        #expect(AskDatabase.sql(in: "```sql\ndelete from orders\n```") == nil)
        #expect(!AskDatabase.isReadOnly("select 1; drop table orders"))
        #expect(!AskDatabase.isReadOnly("with x as (delete from orders returning *) select * from x"))
        #expect(AskDatabase.isReadOnly("select 'drop; it' as note"))                  // words inside strings are fine
    }

    @Test func askThenAnswer() async throws {
        let provider = ScriptedProvider([
            [.completed(Message(role: .assistant, blocks: [.text("```sql\nselect count(*) as n from orders where created_at > now() - interval '7 days'\n```")]), .endTurn, Usage())],
            [.completed(Message(role: .assistant, blocks: [.text("12 orders came in this week.")]), .endTurn, Usage())],
        ])
        let reply = try await AskDatabase.complete(provider, system: AskDatabase.sqlSystem(pg),
                                                   prompt: AskDatabase.sqlPrompt(question: "How many orders this week?", schema: "public.orders(id integer, created_at timestamp)\n"))
        let sql = try #require(AskDatabase.sql(in: reply))
        #expect(provider.requests[0].system.contains("PostgreSQL") && provider.requests[0].tools.isEmpty)
        #expect(provider.requests[0].messages[0].text.contains("public.orders(id integer, created_at timestamp)"))
        let grid = DatabaseBrowser.Grid(columns: ["n"], rows: [["12"]])
        let answer = try await AskDatabase.complete(provider, system: AskDatabase.answerSystem,
                                                    prompt: AskDatabase.answerPrompt(question: "How many orders this week?", sql: sql, grid: grid))
        #expect(answer == "12 orders came in this week.")
        #expect(provider.requests[1].messages[0].text.contains("Result (1 rows):\nn\n12"))
    }
}
