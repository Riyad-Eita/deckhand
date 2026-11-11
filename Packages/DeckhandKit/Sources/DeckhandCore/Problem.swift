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

    /// Classifies an error message (what `localizedDescription` gives) and picks a suggestion.
    public static func from(_ message: String) -> Problem {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { m.contains($0) } }

        if has("host key changed", "host key") && has("changed", "intercept") {
            return Problem(kind: .hostKey, message: text, suggestion: String(localized:
                "Only continue if you know the server was reinstalled. Otherwise ask whoever runs it — someone may be in between."))
        }
        if has("refused the connection") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "Nothing answers SSH on that port. Check the port in the server's settings, or whether the SSH service runs."))
        }
        if has("can't be found", "unknownhost", "could not resolve") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "Check the spelling of the address. Tailscale names only work while Tailscale is on."))
        }
        if has("no answer from", "internet connection appears to be offline", "not connected to the internet",
               "network connection was lost", "network is unreachable", "connect timeout", "request timed out") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "Check that the iPhone is online and the address and port are right. Behind a VPN or firewall, make sure it lets you through."))
        }
        if has("connection to the server was lost", "not connected to the server", "lost the connection") {
            return Problem(kind: .network, message: text, suggestion: String(localized:
                "Pull down or try again. Tasks keep running on the server meanwhile."))
        }
        if has("didn't accept the login", "permission denied (publickey", "no password or key saved") {
            return Problem(kind: .signIn, message: text, suggestion: String(localized:
                "Check the user name and password or key in the server's settings. With a key, its public part must be in ~/.ssh/authorized_keys on the server."))
        }
        if has("rejected the api key", "add an api key", "invalid api key", "invalid x-api-key", "incorrect api key") {
            return Problem(kind: .signIn, message: text, suggestion: String(localized: "Check the API key in Settings."))
        }
        if has("not logged in", "please run /login", "login required", "not signed in") {
            return Problem(kind: .signIn, message: text, suggestion: String(localized:
                "Sign in to the CLI on the server: Server Tools → Sign in."))
        }
        if has("rate limited", "usage limit", "rate limit", "429", "quota") {
            return Problem(kind: .limit, message: text, suggestion: String(localized:
                "Wait until the limit resets, or switch to another model."))
        }
        if has("provider error 5", "overloaded", "unexpected response from the provider", "service unavailable") {
            return Problem(kind: .provider, message: text, suggestion: String(localized:
                "The model provider has a problem right now. Try again in a minute."))
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
        if has("did not finish within", "timed out after") {
            return Problem(kind: .server, message: text, suggestion: String(localized:
                "The server took too long. It may be busy — check Processes, then try again."))
        }
        return Problem(kind: .other, message: text, suggestion: String(localized: "Try again. If it keeps happening, the details help."))
    }
}
