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
