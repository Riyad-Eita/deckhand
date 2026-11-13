import Foundation

/// An error in plain words: what kind of problem it is and what the user can do about it.
public struct Problem: Sendable, Hashable {
    public enum Kind: String, Sendable {
        /// The phone can't reach the server (offline, wrong address or port, firewall, dropped connection).
        case network
        /// Login or key rejected — server, provider or CLI.
        case signIn
        /// The server's identity changed.
        case hostKey
        /// The server answered, but the command failed there (rights, missing program, full disk).
        case server
        /// The model provider had a problem.
        case provider
        /// A usage or rate limit.
        case limit
        case other
    }

    public var kind: Kind
    public var message: String
    public var suggestion: String
    /// The original text when `message` replaced something technical (shown on request).
    public var details: String?

    public init(kind: Kind, message: String, suggestion: String, details: String? = nil) {
        self.kind = kind; self.message = message; self.suggestion = suggestion; self.details = details
    }

    /// Library error descriptions ("ChannelError.ioOnClosedChannel", "Error Domain=… Code=…") aren't for people.
    public static func isTechnical(_ text: String) -> Bool {
        let markers = ["ChannelError", "NIOCore", "NIOSSH", "Citadel", "SSHClientError", "Error Domain=", "Code=", "Error(", "error(",
                       ".swift:", "Swift.", "Foundation."]
        if markers.contains(where: text.contains) { return true }
        return text.range(of: #"^[A-Za-z]+(\.[A-Za-z]+)*\([^)]*\)$"#, options: .regularExpression) != nil
            || text.range(of: #"^[a-z]+[A-Z][A-Za-z]+$"#, options: .regularExpression) != nil
    }

    /// Classifies an error message (what `localizedDescription` gives) and picks a suggestion. Technical texts are
    /// replaced by plain words and kept as `details`.
    public static func from(_ message: String) -> Problem {
        var p = classify(message)
        if isTechnical(p.message) {
            p.details = p.message
            p.message = switch p.kind {
            case .network: String(localized: "The connection to the server closed.")
            case .signIn: String(localized: "The login was rejected.")
            case .hostKey: String(localized: "The server's identity changed.")
            case .server: String(localized: "The server couldn't do this.")
            case .provider: String(localized: "The model provider had a problem.")
            case .limit: String(localized: "A usage limit was reached.")
            case .other: String(localized: "Something went wrong.")
            }
        }
        return p
    }

    static func classify(_ message: String) -> Problem {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { m.contains($0) } }

        if has("host key changed", "host key", "host-schlüssel") && has("changed", "intercept", "geändert", "abfängt") {
            return Problem(kind: .hostKey, message: text, suggestion: String(localized:
                "Only continue if you know the server was reinstalled. Otherwise ask whoever runs it — someone may be in between."))
        }
        if has("refused the connection", "verbindung auf port") && !has("keine antwort") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "Nothing answers SSH on that port. Check the port in the server's settings, or whether the SSH service runs."))
        }
        if has("can't be found", "unknownhost", "could not resolve", "nicht gefunden") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "Check the spelling of the address. Tailscale names only work while Tailscale is on."))
        }
        if has("no answer from", "keine antwort von", "internet connection appears to be offline", "not connected to the internet",
               "internetverbindung", "offline zu sein",
               "network connection was lost", "network is unreachable", "connect timeout", "request timed out") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "Check that the iPhone is online and the address and port are right. Behind a VPN or firewall, make sure it lets you through."))
        }
        if has("connection to the server was lost", "not connected to the server", "lost the connection",
               "verbindung zum server ist abgebrochen", "nicht mit dem server verbunden", "verbindung zum lauf ist abgebrochen") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "Pull down or try again. Tasks keep running on the server meanwhile."))
        }
        if has("didn't accept the login", "permission denied (publickey", "no password or key saved", "anmeldung für") && !has("cli") {
            return Problem(kind: .signIn, message: text, suggestion: String(localized:
                "Check the user name and password or key in the server's settings. With a key, its public part must be in ~/.ssh/authorized_keys on the server."))
        }
        if has("rejected the api key", "add an api key", "invalid api key", "invalid x-api-key", "incorrect api key",
               "api-key abgelehnt", "zuerst einen api-key") {
            return Problem(kind: .signIn, message: text, suggestion: String(localized: "Check the API key in Settings."))
        }
        if has("not logged in", "please run /login", "login required", "not signed in", "nicht angemeldet") {
            return Problem(kind: .signIn, message: text, suggestion: String(localized:
                "Sign in to the CLI on the server: Server Tools → Sign in."))
        }
        if has("rate limited", "usage limit", "rate limit", "429", "quota", "nutzungslimit", "ausgebremst") {
            return Problem(kind: .limit, message: text, suggestion: String(localized:
                "Wait until the limit resets, or switch to another model."))
        }
        if has("provider error 5", "overloaded", "unexpected response from the provider", "service unavailable",
               "fehler beim anbieter 5", "unerwartete antwort vom anbieter") {
            return Problem(kind: .provider, message: text, suggestion: String(localized:
                "The model provider has a problem right now. Try again in a minute."))
        }
        if has("ioonclosedchannel", "connection reset by peer", "broken pipe", "channel closed", "alreadyclosed", "outputclosed",
               "unexpected eof", "connection closed") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "Pull down or try again. Tasks keep running on the server meanwhile."))
        }
        if has("a password is required", "sorry, try again", "incorrect password attempt", "falsches passwort") {
            return Problem(kind: .signIn, message: text, suggestion: String(localized:
                "Check the sudo password — it's the password of your login on the server."))
        }
        if has("is not in the sudoers file", "not allowed to run sudo", "may not run sudo") {
            return Problem(kind: .server, message: text, suggestion: String(localized:
                "Your login isn't allowed to use sudo. Log in as an admin user, or add this user to the sudo group."))
        }
        if has("certificate", "ssl error", "tls") && has("invalid", "untrusted", "expired", "not trusted", "error") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "The HTTPS certificate isn't trusted. Check its expiry and the address you use."))
        }
        if has("read-only file system") {
            return Problem(kind: .server, message: text, suggestion: String(localized:
                "That part of the server can't be written to. The disk may have errors — check the system log."))
        }
        if has("no space left on device", "disk quota exceeded") {
            return Problem(kind: .server, message: text, suggestion: String(localized:
                "The server's disk is full. Free some space — old logs, Docker images, package caches."))
        }
        if has("command not found", "not found in path", "no such file or directory: '") && has("command", "not found") {
            return Problem(kind: .server, message: text, suggestion: String(localized:
                "That program isn't installed on the server, or not in the PATH of your login."))
        }
        if has("permission denied", "operation not permitted", "must be root", "are you root", "requires root") {
            return Problem(kind: .server, message: text, suggestion: String(localized:
                "Your login may not do this. It may need sudo, or a file belongs to another user."))
        }
        if has("did not finish within", "timed out after", "nicht innerhalb von") {
            return Problem(kind: .server, message: text, suggestion: String(localized:
                "The server took too long. It may be busy — check Processes, then try again."))
        }
        if has("no such file or directory", "does not exist", "existiert nicht") {
            return Problem(kind: .server, message: text, suggestion: String(localized:
                "That file or folder isn't there (anymore). Pull down to refresh, or check the path."))
        }
        if has("connection refused") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "Nothing answers on that address and port. Check that the service runs."))
        }
                return Problem(kind: .other, message: text, suggestion: String(localized: "Try again. If it keeps happening, the details help."))
    }
}
