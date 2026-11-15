import Testing
@testable import DeckhandCore

struct HandOffTests {
    @Test func claudeOnDefaultPort() {
        let cmd = HandOff.command(cli: .claudeCode, server: .init(host: "web-1.example.com", user: "deploy"),
                                  directory: "~/shop", sessionID: "0c1b7cea-bdee")
        #expect(cmd == "ssh -t deploy@web-1.example.com 'cd ~/shop && claude --resume 0c1b7cea-bdee'")
    }

    @Test func codexWithPortAndJumpHost() {
        let cmd = HandOff.command(cli: .codex, server: .init(host: "10.0.0.5", port: 2222, user: "me"),
                                  jump: .init(host: "bastion.example.com", port: 2200, user: "jump"),
                                  directory: "/srv/app", sessionID: "abc")
        #expect(cmd.hasPrefix("ssh -t -p 2222 -J jump@bastion.example.com:2200 me@10.0.0.5 "))
        #expect(cmd.contains("codex resume"))
        #expect(cmd.contains("/srv/app"))
    }

    @Test func homeFolderStaysExpandable() {
        #expect(HandOff.folder("~") == "~")
        #expect(HandOff.folder("") == "~")
        #expect(HandOff.folder("~/my app") == "~/'my app'")
        #expect(HandOff.folder("/var/www/it's") == #"'/var/www/it'\''s'"#)
    }

    @Test func remoteCommandRunsInTheFolder() {
        #expect(HandOff.remoteCommand(cli: .claudeCode, directory: "~", sessionID: "s1") == "cd ~ && claude --resume s1")
        // Anything the shell would read differently is quoted.
        #expect(HandOff.remoteCommand(cli: .codex, directory: "~/a b", sessionID: "x;rm") == "cd ~/'a b' && codex resume 'x;rm'")
    }
}
