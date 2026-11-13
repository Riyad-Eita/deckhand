import Foundation
import Testing
@testable import DeckhandCore

@Suite struct HTTPClientTests {
    typealias H = HTTPClient

    @Test func substitutesVariablesAndReportsMissing() {
        var missing = Set<String>()
        let out = H.substitute("{{base}}/users/{{ id }}?k={{nope}}", ["base": "https://api.example.com", "id": "7"], missing: &missing)
        #expect(out == "https://api.example.com/users/7?k={{nope}}")
        #expect(missing == ["nope"])
        var m2 = Set<String>()
        #expect(H.substitute("open {{brace", [:], missing: &m2) == "open {{brace")
    }

    @Test func resolvesAuthHeadersAndJSONContentType() {
        let r = H.Request(name: "x", method: .POST, url: "{{base}}/items",
                          headers: [.init(name: "X-Trace", value: "{{trace}}"), .init(name: "X-Off", value: "1", enabled: false)],
                          body: #"{"name": "{{name}}"}"#, auth: .bearer("{{token}}"))
        let res = H.resolve(r, variables: ["base": "api.example.com", "trace": "abc", "token": "t0k", "name": "box"])
        #expect(res.url == "https://api.example.com/items")
        #expect(res.headers.map(\.0) == ["X-Trace", "Authorization", "Content-Type"])
        #expect(res.headers[1].1 == "Bearer t0k")
        #expect(res.headers[2].1 == "application/json")
        #expect(res.body == #"{"name": "box"}"#)
        #expect(res.missing.isEmpty)

        let basic = H.resolve(H.Request(name: "b", url: "http://example.com", auth: .basic(user: "me", password: "pw")), variables: [:])
        #expect(basic.headers.first?.1 == "Basic " + Data("me:pw".utf8).base64EncodedString())
        #expect(basic.url == "http://example.com")
        // Plain text body: no content type guessed.
        let text = H.resolve(H.Request(name: "t", method: .POST, url: "example.com", body: "a=1"), variables: [:])
        #expect(!text.headers.contains { $0.0 == "Content-Type" })
    }

    @Test func curlCommandQuotesEverything() {
        let res = H.resolve(H.Request(name: "x", method: .POST, url: "https://example.com/a?b=1&c='2'",
                                      headers: [.init(name: "X-Note", value: "it's $HOME")], body: "@/etc/passwd"), variables: [:])
        let cmd = H.curlCommand(res)
        #expect(cmd.contains("--data-raw '@/etc/passwd'"))
        #expect(cmd.contains(#"-H 'X-Note: it'\''s $HOME'"#))
        #expect(cmd.contains(#"-- 'https://example.com/a?b=1&c='\''2'\'''"#))
        #expect(cmd.contains("-X POST"))
        let get = H.curlCommand(H.resolve(H.Request(name: "g", url: "example.com", body: "ignored"), variables: [:]))
        #expect(!get.contains("--data-raw"))
    }

    @Test func parsesCurlOutputSkippingInterimResponses() throws {
        let out = "HTTP/1.1 100 Continue\r\n\r\nHTTP/2 201\r\ncontent-type: application/json\r\nX-Id: 9\r\n\r\n{\"ok\":true,\"a\":[1]}\n@@meta 201 0.142 19"
        let r = try #require(H.parseCurl(out))
        #expect(r.status == 201)
        #expect(r.headers["content-type"] == "application/json")
        #expect(r.headers["x-id"] == "9")
        #expect(r.body == "{\"ok\":true,\"a\":[1]}")
        #expect(r.seconds == 0.142)
        #expect(r.bytes == 19)
        #expect(r.reason == "Created")
        #expect(H.Response(status: 299, headers: [:], body: "", seconds: 0, bytes: 0).reason == "Success")
        #expect(r.prettyBody.contains("\"a\" : [\n"))
        #expect(H.parseCurl("curl: (6) Could not resolve host") == nil)
        // Empty body (204).
        let empty = try #require(H.parseCurl("HTTP/1.1 204 No Content\r\nServer: x\r\n\r\n\n@@meta 204 0.01 0"))
        #expect(empty.status == 204 && empty.body.isEmpty)
    }

    @Test func importsCopyAsCurl() throws {
        let cmd = """
        curl 'https://api.example.com/v1/items?limit=5' \\
          -H 'accept: application/json' \\
          -H 'authorization: Bearer abc.def' \\
          --data-raw $'{"name":"it\\'s"}' \\
          --compressed
        """
        let r = try #require(H.importCurl(cmd))
        #expect(r.method == .POST)
        #expect(r.url == "https://api.example.com/v1/items?limit=5")
        #expect(r.headers.map(\.name) == ["accept"])
        #expect(r.auth == .bearer("abc.def"))
        #expect(r.body == #"{"name":"it's"}"#)
        #expect(r.name == "POST api.example.com/v1/items")

        let basic = try #require(H.importCurl(#"curl -X DELETE -u "me:p w" https://example.com/x/1"#))
        #expect(basic.method == .DELETE)
        #expect(basic.auth == .basic(user: "me", password: "p w"))
        #expect(H.importCurl("wget https://example.com") == nil)
    }

    @Test func collectionsRoundTripAsJSON() throws {
        var c = H.Collection(name: "Shop API", requests: [H.Request(name: "List", url: "{{base}}/items")],
                             environments: [H.Environment(name: "Staging", variables: [.init(name: "base", value: "https://staging.example.com"),
                                                                                        .init(name: "token", value: "", secret: true)])])
        c.activeEnvironment = c.environments[0].id
        let back = try JSONDecoder().decode(H.Collection.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
}
