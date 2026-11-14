import Foundation
import Testing
@testable import DeckhandCore

struct HostLinkTests {
    @Test func roundTrip() throws {
        let c = HostImport.Candidate(name: "Web & DB", host: "web-1.example.com", port: 2222, user: "deploy",
                                     proxyJump: "admin@bastion.example.com:22")
        let link = HostLink.link(for: c)
        #expect(link.hasPrefix("deckhand://add?"))
        let url = try #require(URL(string: link))
        let back = try #require(HostLink.parse(url))
        #expect(back == c)
    }

    @Test func defaults() throws {
        let c = try #require(HostLink.parse(URL(string: "deckhand://add?host=203.0.113.10")!))
        #expect(c.user == "root" && c.port == 22 && c.name == "203.0.113.10" && c.proxyJump == nil)
        #expect(HostLink.link(for: c) == "deckhand://add?host=203.0.113.10&user=root")
    }

    @Test func sshURLs() throws {
        let c = try #require(HostLink.parse(URL(string: "ssh://me@example.com:2200")!))
        #expect(c.user == "me" && c.host == "example.com" && c.port == 2200)
        // A password in the URL is refused rather than silently dropped.
        #expect(HostLink.parse(URL(string: "ssh://me:secret@example.com")!) == nil)
    }

    @Test func unsafeFieldsAreRefused() {
        for bad in [
            "deckhand://add?host=-oProxyCommand=evil",
            "deckhand://add?host=a%20b",
            "deckhand://add?host=example.com&user=-l",
            "deckhand://add?host=example.com&user=a;rm",
            "deckhand://add?host=example.com&port=0",
            "deckhand://add?host=example.com&port=70000",
            "deckhand://add?host=example.com&jump=-J",
            "deckhand://add?user=me",
            "deckhand://thread/x",
            "https://example.com",
        ] {
            #expect(HostLink.parse(URL(string: bad)!) == nil, "\(bad)")
        }
    }

    @Test func namesAreCleaned() throws {
        let c = try #require(HostLink.parse(URL(string: "deckhand://add?host=example.com&name=a%0Ab" + String(repeating: "x", count: 100))!))
        #expect(!c.name.contains("\n") && c.name.count == 64)
    }

    @Test func textWithLinks() {
        let text = """
        Our servers:
        deckhand://add?host=web.example.com&user=deploy
        ssh://me@db.example.com
        not a link
        """
        #expect(HostImport.parse(text).map(\.host) == ["web.example.com", "db.example.com"])
        // Configs still parse as before.
        #expect(HostImport.parse("Host a\n  HostName a.example.com").map(\.host) == ["a.example.com"])
    }
}
