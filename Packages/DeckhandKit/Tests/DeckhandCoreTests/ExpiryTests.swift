import Foundation
import Testing
@testable import DeckhandCore

struct ExpiryTests {
    @Test func registeredDomain() {
        #expect(Expiry.registrable("shop.example.com") == "example.com")
        #expect(Expiry.registrable("a.b.example.co.uk") == "example.co.uk")
        #expect(Expiry.registrable("example.org") == "example.org")
    }

    @Test func parsesStatusAndSuggestions() {
        let s = Expiry.parseStatus("""
        @@installed
        @@domain shop.example.com
        @@domain new.example.com
        @@status shop.example.com\t1800000000\tLet's Encrypt\t1900000000\t1799000000
        @@suggest shop.example.com
        @@suggest api.example.com
        """)
        #expect(s.installed && s.entries.map(\.domain) == ["shop.example.com", "new.example.com"])
        let e = s.entries[0]
        #expect(e.issuer == "Let's Encrypt" && e.daysLeft(e.certificateEnd, now: Date(timeIntervalSince1970: 1_799_000_000)) == 11)
        #expect(s.entries[1].certificateEnd == nil)
        #expect(s.suggestions == ["api.example.com"])
    }

    @Test func addRejectsWhatIsNotADomain() {
        #expect(Expiry.addCommand("not a domain; rm -rf ~") == "echo '@@failed invalid'")
        #expect(Expiry.addCommand("Shop.Example.com").contains("'example.com' > \"$D/reg.shop.example.com\""))
    }
}
