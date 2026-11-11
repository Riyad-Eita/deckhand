import Foundation
import Testing
@testable import DeckhandCore

struct DomainsTests {
    @Test func validation() {
        #expect(Domains.Domain.isValidName("shop.example.com") && Domains.Domain.isValidName("a.b.co"))
        #expect(!Domains.Domain.isValidName("Shop.example.com") && !Domains.Domain.isValidName("localhost") && !Domains.Domain.isValidName("x;rm -rf /.com"))
        #expect(Domains.Domain.isValidUpstream("127.0.0.1:3000") && Domains.Domain.isValidUpstream("http://localhost:8080/app"))
        #expect(!Domains.Domain.isValidUpstream("3000") && !Domains.Domain.isValidUpstream("127.0.0.1:3000; reboot"))
    }

    @Test func dnsAndConflicts() {
        let ok = Domains.parseCheck("@@resolves 203.0.113.5\n@@local 10.0.0.2\n@@public 203.0.113.5\n@@port 80 caddy\n@@caddy yes\n")
        #expect(ok.dnsOK && ok.conflict == nil)
        let busy = Domains.parseCheck("@@resolves 198.51.100.9\n@@local 203.0.113.5\n@@port 80 nginx\n@@caddy no\n")
        #expect(!busy.dnsOK && busy.conflict == "nginx")
        #expect(Domains.parseCheck("@@local 203.0.113.5\n@@caddy no").dnsOK == false)
    }

    @Test func changeAndStatus() {
        let c = Domains.addChange(.init(name: "shop.example.com", upstream: "127.0.0.1:3000"))
        #expect(c.files == ["/etc/caddy/deckhand.d/shop.example.com.caddy", "/etc/caddy/Caddyfile"])
        #expect(c.apply.contains("# deckhand-domain shop.example.com\nshop.example.com {\n\treverse_proxy 127.0.0.1:3000\n}"))
        #expect(c.apply.contains("import /etc/caddy/deckhand.d/*.caddy"))
        #expect(Domains.removeChange("shop.example.com").apply == "rm -f /etc/caddy/deckhand.d/shop.example.com.caddy")
        #expect(c.validate.contains("caddy validate"))
        let s = Domains.parseStatus("@@caddy active\n@@domain shop.example.com\t127.0.0.1:3000\t0\t1800000000\tLet's Encrypt\t200\n")
        #expect(s.caddy == "active" && s.domains.first?.issuer == "Let's Encrypt" && s.domains.first?.upstreamOK == true)
    }
}
