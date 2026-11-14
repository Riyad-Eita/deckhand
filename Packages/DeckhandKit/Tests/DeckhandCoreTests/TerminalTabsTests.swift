import Foundation
import Testing
@testable import DeckhandCore

@Suite struct TerminalTabsTests {
    @Test func sessionNames() {
        #expect(PersistentSession.name(tab: 1) == "deckhand")
        #expect(PersistentSession.name(tab: 3) == "deckhand-3")
        let a = PersistentSession.attachCommand(tab: 2)
        #expect(a.contains("tmux new-session -A -s deckhand-2 \\; set-option set-titles on"))
        #expect(!a.contains("-g "))
        #expect(a.contains("screen -xRR -S deckhand-2"))
        #expect(PersistentSession.attachCommand == PersistentSession.attachCommand(tab: 1))
        #expect(PersistentSession.endCommand(tab: 2).hasPrefix("tmux kill-session -t deckhand-2"))
    }

    @Test func numbersAndTitles() {
        #expect(TerminalTabs.next(after: []) == 1)
        #expect(TerminalTabs.next(after: [1, 2, 4]) == 3)
        #expect(TerminalTabs.title("htop", tab: 2) == "htop")
        #expect(TerminalTabs.title("tester@web-1: ~/app", tab: 1) == "~/app")
        #expect(TerminalTabs.title("bash", tab: 2) == "Shell 2")
        #expect(TerminalTabs.title(nil, tab: 3) == "Shell 3")
        #expect(TerminalTabs.title("tail -f /var/log/nginx/access.log", tab: 1).count == 24)
    }
}
