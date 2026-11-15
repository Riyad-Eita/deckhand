import Testing
@testable import DeckhandCore

struct MacSetupTests {
    @Test func displayNameFromBonjourName() {
        #expect(MacSetup.displayName(hostName: "Riads-MacBook-Pro.local") == "Riads MacBook Pro")
        #expect(MacSetup.displayName(hostName: "studio") == "studio")
        #expect(MacSetup.displayName(hostName: "") == "Mac")
    }

    @Test func addressPrefersOverride() {
        #expect(MacSetup.address(hostName: "studio") == "studio.local")
        #expect(MacSetup.address(hostName: "studio.local") == "studio.local")
        #expect(MacSetup.address(hostName: "studio.local", override: " studio.tail1234.ts.net ") == "studio.tail1234.ts.net")
    }

    @Test func linkCarriesNoSecrets() throws {
        let link = try #require(MacSetup.link(hostName: "Riads-MacBook-Pro.local", user: "me"))
        #expect(link.hasPrefix("deckhand://add?"))
        #expect(link.contains("host=Riads-MacBook-Pro.local"))
        #expect(link.contains("user=me"))
        #expect(!link.lowercased().contains("pass"))
        #expect(MacSetup.link(hostName: "", user: "me") == nil)
        #expect(MacSetup.link(hostName: "a.local", user: " ") == nil)
    }
}
