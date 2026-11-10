import Foundation
import Testing
@testable import DeckhandCore

@Suite struct SyntaxHighlighterTests {
    typealias H = SyntaxHighlighter

    /// The text of each token of one line, with its kind.
    func spans(_ line: String, _ lang: H.Language, state: H.State = .normal) -> [String] {
        let ns = line as NSString
        return H.highlight(line: Substring(line), language: lang, state: state).0
            .map { "\($0.kind.rawValue):\(ns.substring(with: NSRange(location: $0.start, length: $0.length)))" }
    }

    @Test func picksLanguagesByFileName() {
        #expect(H.language(forFileName: "main.swift")?.name == "Swift")
        #expect(H.language(forFileName: "App.TSX")?.name == "JavaScript")
        #expect(H.language(forFileName: "Dockerfile")?.name == "Dockerfile")
        #expect(H.language(forFileName: "Dockerfile.prod")?.name == "Dockerfile")
        #expect(H.language(forFileName: "docker-compose.yml")?.name == "YAML")
        #expect(H.language(forFileName: "nginx.conf")?.name == "TOML")
        #expect(H.language(forFileName: ".env")?.name == "Shell")
        #expect(H.language(forFileName: "README") == nil)
        #expect(H.language(forFileName: "notes.txt") == nil)
    }

    @Test func swiftLine() {
        #expect(spans("let x = \"hi\" // note", H.swift) == ["keyword:let", "string:\"hi\"", "comment:// note"])
        #expect(spans("func load(id: UUID) async throws -> Int { 42 }", H.swift)
            == ["keyword:func", "type:UUID", "keyword:async", "keyword:throws", "type:Int", "number:42"])
        #expect(spans("let s = \"a \\\"quoted\\\" b\"", H.swift) == ["keyword:let", "string:\"a \\\"quoted\\\" b\""])
    }

    @Test func blockCommentsSpanLines() {
        let lines: [Substring] = ["let a = 1 /* start", "still comment", "end */ let b = 2"]
        let t = H.highlight(lines, language: H.swift)
        #expect(t[0].last?.kind == .comment)
        #expect(t[1] == [H.Token(kind: .comment, start: 0, length: 13)])
        #expect(t[2].first == H.Token(kind: .comment, start: 0, length: 6))
        #expect(t[2].contains { $0.kind == .keyword })
        #expect(t[2].last?.kind == .number)
    }

    @Test func pythonTripleQuotes() {
        let lines: [Substring] = ["def f():", "    \"\"\"Doc", "    more\"\"\"", "    return None  # done"]
        let t = H.highlight(lines, language: H.python)
        #expect(t[0].first?.kind == .keyword)
        #expect(t[1].last?.kind == .string)
        #expect(t[2] == [H.Token(kind: .string, start: 0, length: 11)])
        #expect(t[3].map(\.kind) == [.keyword, .keyword, .comment])
    }

    @Test func shellCommentsVariablesAndHashes() {
        #expect(spans("echo \"$HOME\" ${PATH} # hi", H.shell) == ["keyword:echo", "string:\"$HOME\"", "type:${PATH}", "comment:# hi"])
        #expect(spans("n=$#", H.shell).isEmpty)
        #expect(!spans("curl http://x/#anchor", H.shell).contains { $0.hasPrefix("comment") })
    }

    @Test func yamlKeysAndValues() {
        #expect(spans("  image: nginx:1.27 # pinned", H.yaml) == ["key:image", "number:1.27", "comment:# pinned"])
        #expect(spans("- name: web", H.yaml) == ["key:name"])
        #expect(spans("url: http://example.com", H.yaml) == ["key:url"])
        #expect(spans("enabled: true", H.yaml) == ["key:enabled", "keyword:true"])
        #expect(spans("[server]", H.toml) == ["type:[server]"])
        #expect(spans("port = 8080", H.toml) == ["key:port", "number:8080"])
    }

    @Test func jsonKeysAndStrings() {
        #expect(spans("{\"name\": \"deckhand\", \"stars\": 5, \"ok\": true}", H.json)
            == ["key:\"name\"", "string:\"deckhand\"", "key:\"stars\"", "number:5", "key:\"ok\"", "keyword:true"])
    }

    @Test func markupTagsAndComments() {
        #expect(spans("<div class=\"a\"><!-- x --></div>", H.markup) == ["tag:<div", "string:\"a\"", "comment:<!-- x -->", "tag:</div"])
    }

    @Test func numbersInsideWordsStayPlain() {
        #expect(spans("let v2 = 0x1F", H.swift) == ["keyword:let", "number:0x1F"])
    }

    @Test func unicodeOffsetsAreUTF16() {
        let line = "let s = \"🚀 ok\" // ü"
        let toks = H.highlight(line: Substring(line), language: H.swift, state: .normal).0
        let ns = line as NSString
        #expect(toks.map { ns.substring(with: NSRange(location: $0.start, length: $0.length)) } == ["let", "\"🚀 ok\"", "// ü"])
    }

    @Test func longLinesStayPlainButKeepState() {
        let long = Substring(String(repeating: "x", count: H.maxLineLength + 1))
        let (tokens, state) = H.highlight(line: long, language: H.swift, state: .blockComment)
        #expect(tokens.isEmpty && state == .blockComment)
    }

    @Test func largeFileIsFast() {
        let line = "    let value = compute(\"key\", 42) // comment with words"
        let lines = Array(repeating: Substring(line), count: 20_000)
        let start = Date()
        let t = H.highlight(lines, language: H.swift)
        #expect(t.count == 20_000)
        #expect(Date().timeIntervalSince(start) < 2.0)
    }

    @Test func searchFindsAllMatchesCaseInsensitive() {
        let lines: [Substring] = ["Hello world", "nothing", "WORLD and world", "Wörld"]
        let m = TextSearch.matches(in: lines, query: "world")
        #expect(m.map(\.line) == [0, 2, 2, 3])
        #expect(m[1].start == 0 && m[2].start == 10 && m[0].length == 5)
        #expect(TextSearch.matches(in: lines, query: "").isEmpty)
        #expect(TextSearch.matches(in: lines, query: "o", limit: 3).count == 3)
    }
}
