import Foundation
import Testing
@testable import DeckhandCore

@Suite struct TerminalSessionsTests {
    @Test func parsesTmuxAndScreen() {
        let out = "T\tdeckhand\t1\t1\t1795860000\nT\tbuild\t3\t0\t1795869999\nT\tdeckhand-2\t1\t0\t1795800000\n"
            + "S\t12345.logs\tDetached\nS\t999.deckhand\tAttached\nHAS_TMUX\nHAS_SCREEN\n"
        let l = TerminalSessions.parse(out)
        #expect(l.hasTmux && l.hasScreen)
        #expect(l.sessions.map(\.name) == ["build", "deckhand", "deckhand-2", "12345.logs", "999.deckhand"])
        #expect(l.sessions[0].windows == 3 && !l.sessions[0].attached)
        #expect(l.sessions[1].attached && l.sessions[1].isDeckhandTab)
        #expect(l.sessions[2].isDeckhandTab && !l.sessions[0].isDeckhandTab)
        #expect(l.sessions[3].shortName == "logs" && !l.sessions[3].attached)
        #expect(l.sessions[4].attached && l.sessions[4].isDeckhandTab)
        #expect(!TerminalSessions.Session(kind: .tmux, name: "deckhand-x").isDeckhandTab)
        #expect(TerminalSessions.parse("").sessions.isEmpty && !TerminalSessions.parse("").hasTmux)
    }

    @Test func commandsQuoteNames() {
        let s = TerminalSessions.Session(kind: .tmux, name: "it's mine")
        #expect(TerminalSessions.attachCommand(s).hasSuffix("exec tmux attach-session -t '=it'\\''s mine'"))
        #expect(TerminalSessions.killCommand(s).hasSuffix("tmux kill-session -t '=it'\\''s mine'"))
        #expect(TerminalSessions.attachCommand(.init(kind: .screen, name: "12.logs")) == "exec screen -x '12.logs'")
        #expect(TerminalSessions.clean(" a.b:c ") == "a-b-c" && TerminalSessions.clean("") == "work")
        #expect(PersistentSession.attachCommand.hasPrefix(TerminalSessions.path))
    }

    @Test func buildChecksEveryDownload() {
        let script = TmuxInstall.buildScript
        for s in TmuxInstall.sources {
            #expect(s.url.hasPrefix("https://"))
            #expect(s.sha256.count == 64)
            #expect(script.contains(s.sha256))
        }
        #expect(script.contains("@@badsum") && script.contains("@@nocc") && script.contains("$HOME/.local"))
        #expect(TmuxInstall.packageScript.contains("apt-get install -y tmux"))
    }
}
