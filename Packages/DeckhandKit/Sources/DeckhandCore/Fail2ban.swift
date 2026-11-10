import Foundation

/// fail2ban: which addresses are banned and why, unbanning, and keeping your own addresses off the list.
public enum Fail2ban {
    public struct Jail: Sendable, Hashable, Identifiable {
        public var name: String
        public var currentlyFailed: Int
        public var totalFailed: Int
        public var totalBanned: Int
        public var banned: [String]
        public var id: String { name }

        /// What the jail watches, in plain words.
        public var reason: String {
            switch name {
            case "sshd": "Failed SSH logins"
            case "recidive": "Banned again and again"
            case let n where n.hasPrefix("nginx-http-auth") || n.hasPrefix("apache-auth"): "Failed website logins"
            case let n where n.contains("botsearch") || n.contains("noscript") || n.contains("badbots"): "Scanning the website for weak spots"
            case let n where n.contains("limit-req"): "Too many web requests"
            default: name
            }
        }
    }

    public struct Status: Sendable, Hashable {
        public var installed: Bool
        public var running: Bool
        public var jails: [Jail]
        /// Addresses fail2ban never bans.
        public var ignored: [String]
        /// The address this SSH connection comes from, as the server sees it.
        public var myAddress: String?
        /// Ports sshd listens on (for setting up the sshd jail).
        public var sshPorts: [Int] = [22]
    }

    public static let allowListFile = "/etc/fail2ban/jail.d/deckhand-allow.local"

    /// The address this SSH connection comes from (run without sudo: sudo drops SSH_CLIENT).
    public static let myAddressCommand = #"printf '%s' "${SSH_CLIENT%% *}""#

    /// Root script. One `@@jail <name>` block per jail with `fail2ban-client status <name>` output.
    public static let statusScript = #"""
    echo "@@sshports $(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')"
    if ! command -v fail2ban-client >/dev/null 2>&1; then echo '@@notinstalled'; exit 0; fi
    if ! fail2ban-client ping >/dev/null 2>&1; then echo '@@stopped'; exit 0; fi
    for j in $(fail2ban-client status | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do
      echo "@@jail $j"; fail2ban-client status "$j"
    done
    echo "@@ignore $(fail2ban-client get sshd ignoreip 2>/dev/null | sed -n 's/^[|`]- //p' | tr '\n' ' ')"
    """#

    public static func parse(_ output: String) -> Status {
        var s = Status(installed: true, running: true, jails: [], ignored: [], myAddress: nil)
        var current: Jail?
        func value(_ line: String) -> String {
            guard let colon = line.firstIndex(of: ":") else { return "" }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        for raw in output.split(separator: "\n").map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@sshports") {
                let p = line.split(separator: " ").dropFirst().compactMap { Int($0) }
                if !p.isEmpty { s.sshPorts = p }
                continue
            }
            if line == "@@notinstalled" { s.installed = false; s.running = false; continue }
            if line == "@@stopped" { s.running = false; continue }
            if line.hasPrefix("@@jail ") {
                if let current { s.jails.append(current) }
                current = Jail(name: String(line.dropFirst(7)), currentlyFailed: 0, totalFailed: 0, totalBanned: 0, banned: [])
                continue
            }
            if line.hasPrefix("@@ignore") {
                if let c = current { s.jails.append(c); current = nil }
                s.ignored = line.dropFirst(8).split(separator: " ").map(String.init)
                continue
            }
            guard current != nil else { continue }
            if line.contains("Currently failed:") { current!.currentlyFailed = Int(value(line)) ?? 0 }
            else if line.contains("Total failed:") { current!.totalFailed = Int(value(line)) ?? 0 }
            else if line.contains("Total banned:") { current!.totalBanned = Int(value(line)) ?? 0 }
            else if line.contains("Banned IP list:") { current!.banned = value(line).split(separator: " ").map(String.init) }
        }
        if let current { s.jails.append(current) }
        return s
    }

    static func isAddress(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-fA-F:.]+(/\d{1,3})?$"#, options: .regularExpression) != nil
    }

    public static func unbanScript(_ ip: String, jail: String) -> String? {
        guard isAddress(ip), jail.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        return "fail2ban-client set \(ShellQuote.quote(jail)) unbanip \(ShellQuote.quote(ip)) && echo '@@done'"
    }

    /// Keeps `addresses` (plus localhost) off the ban list for every jail. Unbans them right away too.
    public static func allowList(_ addresses: [String]) -> ConfigChange? {
        let list = addresses.filter { isAddress($0) && !["127.0.0.1/8", "127.0.0.0/8", "::1"].contains($0) }
        guard !list.isEmpty else { return nil }
        let line = (["127.0.0.1/8", "::1"] + list).joined(separator: " ")
        let content = ["# Added by Deckhand: addresses fail2ban never bans", "[DEFAULT]", "ignoreip = \(line)"]
            .map(ShellQuote.quote).joined(separator: " ")
        let unban = list.map { "fail2ban-client unban \(ShellQuote.quote($0)) >/dev/null 2>&1 || true" }.joined(separator: "\n")
        return ConfigChange(
            title: "Never ban \(list.joined(separator: ", "))", files: [allowListFile],
            apply: "mkdir -p /etc/fail2ban/jail.d\nprintf '%s\\n' \(content) > \(allowListFile)",
            validate: "fail2ban-client -t >/dev/null 2>&1",
            reload: "fail2ban-client reload >/dev/null\n" + unban)
    }
}
