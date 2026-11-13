import Foundation
import Testing
@testable import DeckhandCore

@Suite struct ProblemTests {
    @Test(arguments: [
        ("No answer from example.com on port 22.", Problem.Kind.network),
        ("example.com refused the connection on port 2222.", .network),
        ("The address no-such-host.invalid can't be found.", .network),
        ("The Internet connection appears to be offline.", .network),
        ("The connection to the server was lost.", .network),
        ("The server didn't accept the login for me.", .signIn),
        ("No password or key saved for this server.", .signIn),
        ("The provider rejected the API key (401). invalid x-api-key", .signIn),
        ("Not logged in · Please run /login", .signIn),
        ("The server's host key changed (expected A, got B). This can mean someone is intercepting the connection.", .hostKey),
        ("Rate limited by the provider. Slow down", .limit),
        ("Provider error 529: Overloaded", .provider),
        ("mkdir: cannot create directory '/x': Permission denied", .server),
        ("bash: line 1: rg: command not found", .server),
        ("write error: No space left on device", .server),
        ("The command did not finish within 30 s.", .server),
        ("Something odd happened", .other),
    ])
    func classifies(message: String, kind: Problem.Kind) {
        let p = Problem.from(message)
        #expect(p.kind == kind, "\(message)")
        #expect(!p.suggestion.isEmpty)
        #expect(p.message == message)
    }

    @Test func trimsTheMessage() {
        #expect(Problem.from("  The connection to the server was lost.\n").message == "The connection to the server was lost.")
    }

    @Test func classifiesGermanMessages() {
        #expect(Problem.from("Keine Antwort von example.com auf Port 1.").kind == .network)
        #expect(Problem.from("example.com hat die Verbindung auf Port 22 abgelehnt.").kind == .network)
        #expect(Problem.from("Der Server hat die Anmeldung für deploy nicht angenommen.").kind == .signIn)
        #expect(Problem.from("Hinterlege zuerst einen API-Key in den Einstellungen.").kind == .signIn)
        #expect(Problem.from("Der Befehl wurde nicht innerhalb von 30 s fertig.").kind == .server)
    }
}

@Suite struct PlainProblemTests {
    @Test func technicalTextBecomesPlainWithDetails() {
        let p = Problem.from("NIOCore.ChannelError.ioOnClosedChannel")
        #expect(p.kind == .network)
        #expect(p.message == "The connection to the server closed.")
        #expect(p.details == "NIOCore.ChannelError.ioOnClosedChannel")
        let ns = Problem.from("The operation couldn’t be completed. (Citadel.SSHClientError error 3.)")
        #expect(ns.details != nil && ns.message != ns.details)
        let camel = Problem.from("ioOnClosedChannel")
        #expect(camel.kind == .network && camel.details == "ioOnClosedChannel")
        // Plain sentences stay as they are.
        let plain = Problem.from("Nothing answers on port 8080 on the server.")
        #expect(plain.details == nil && plain.message == "Nothing answers on port 8080 on the server.")
    }

    @Test func moreKinds() {
        #expect(Problem.from("sudo: a password is required").kind == .signIn)
        #expect(Problem.from("Sorry, try again.").suggestion.contains("sudo password"))
        #expect(Problem.from("deploy is not in the sudoers file.  This incident will be reported.").suggestion.contains("sudo group"))
        #expect(Problem.from("cat: /etc/foo.conf: No such file or directory").suggestion.contains("isn't there"))
        #expect(Problem.from("write error: Broken pipe").kind == .network)
        #expect(Problem.from("curl: (7) Failed to connect to 127.0.0.1 port 8080: Connection refused").kind == .network)
        #expect(Problem.from("touch: cannot touch 'x': Read-only file system").kind == .server)
        #expect(Problem.from("SSL error: certificate has expired").kind == .network)
    }
}
