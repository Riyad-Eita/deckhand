import Foundation

/// Presets for the kinds of servers people run: which ports the firewall lets in (and from where), which protective
/// services run, and which check-up items matter. A plan says per server what will change, what is already fine and
/// what the firewall will close — before anything is touched. Every change is reversible (`ConfigChange`).
public enum HardeningProfile: String, CaseIterable, Sendable, Identifiable {
    case webServer, database, homeLab

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .webServer: String(localized: "Web server")
        case .database: String(localized: "Database server")
        case .homeLab: String(localized: "Home lab")
        }
    }

    public var summary: String {
        switch self {
        case .webServer: String(localized: "SSH, HTTP and HTTPS open to everyone; everything else closed.")
        case .database: String(localized: "Only SSH is public. The database port opens just for the app servers you name.")
        case .homeLab: String(localized: "SSH from anywhere; your services only from your home network and Tailscale.")
        }
    }

    public var symbol: String {
        switch self {
        case .webServer: "globe"
        case .database: "cylinder.split.1x2"
        case .homeLab: "house"
        }
    }

    /// Check-up items this profile cares about (ids of `SecurityAudit.checks`).
    public var checkIDs: [String] {
        let common = ["ssh.password", "ssh.root", "firewall", "fail2ban", "autoupdates", "updates", "ports"]
        switch self {
        case .webServer: return common + ["docker", "reboot"]
        case .database: return common + ["docker", "accounts"]
        case .homeLab: return common + ["docker", "timesync"]
        }
    }

    public static let databasePorts: [Int] = [5432, 3306, 6379, 27017, 9200, 11211, 5984]
    /// Private ranges plus Tailscale's (CGNAT) range.
    public static let homeRanges = ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "100.64.0.0/10"]
}

public enum HardeningPlan {
    public struct Rule: Sendable, Hashable {
        public var port: Int
        /// nil: from anywhere.
        public var source: String?
        public init(port: Int, source: String? = nil) { self.port = port; self.source = source }
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public enum State: Sendable, Equatable {
            /// A reversible change; `guarded` ones are confirmed by a fresh login or rolled back.
            case change(ConfigChange, guarded: Bool)
            case alreadyFine
            case notPossible(String)
        }
        public var id: String
        public var title: String
        public var detail: String
        public var state: State
        public var willChange: Bool { if case .change = state { true } else { false } }
    }

    public struct Plan: Sendable, Equatable {
        public var profile: HardeningProfile
        public var rules: [Rule]
        /// Ports that listen publicly now and that the firewall will close.
        public var closes: [Int]
        public var items: [Item]
        public var warnings: [String]
        public var changes: [Item] { items.filter(\.willChange) }
    }

    /// Valid IPv4 address or CIDR (what the database profile accepts as app servers).
    public static func isValidSource(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        if parts.count == 2 { guard let bits = Int(parts[1]), (0...32).contains(bits) else { return false } }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { o in Int(o).map { (0...255).contains($0) && String($0) == o } ?? false }
    }

    /// The plan for one server, from its check-up facts.
    public static func plan(_ profile: HardeningProfile, facts f: SecurityAudit.Facts, context: SecurityAudit.Context,
                            databaseClients: [String] = []) -> Plan {
        let sshPorts = f.list("ssh.ports").compactMap(Int.init).nilIfEmpty ?? [22]
        let publicPorts = f.list("public").compactMap(Int.init)
        var rules = sshPorts.map { Rule(port: $0) }
        var warnings: [String] = []

        switch profile {
        case .webServer:
            rules += [Rule(port: 80), Rule(port: 443)]
        case .database:
            let clients = databaseClients.filter(isValidSource)
            let dbPorts = publicPorts.filter { HardeningProfile.databasePorts.contains($0) }
            for p in dbPorts { for c in clients { rules.append(Rule(port: p, source: c)) } }
            if !dbPorts.isEmpty && clients.isEmpty {
                warnings.append(String(localized: "No app servers named: the database is then only reachable on the server itself and through SSH."))
            }
        case .homeLab:
            for p in publicPorts where !sshPorts.contains(p) {
                for r in HardeningProfile.homeRanges { rules.append(Rule(port: p, source: r)) }
            }
        }
        let openToAll = Set(rules.filter { $0.source == nil }.map(\.port))
        let closes = publicPorts.filter { p in !openToAll.contains(p) && !rules.contains { $0.port == p } }.sorted()
        let limited = Set(rules.filter { $0.source != nil }.map(\.port)).subtracting(openToAll).sorted()

        if !f["dockerpublic"].isEmpty {
            warnings.append(String(localized: "Docker publishes ports past the firewall (\(f["dockerpublic"])). Bind them to 127.0.0.1 in the compose file or put a reverse proxy in front."))
        }

        var items: [Item] = []
        // Firewall
        let firewallDetail: String = {
            var parts = [String(localized: "Open to everyone: \(openToAll.sorted().map(String.init).joined(separator: ", "))")]
            if !limited.isEmpty { parts.append(String(localized: "Limited: \(limited.map(String.init).joined(separator: ", "))")) }
            if !closes.isEmpty { parts.append(String(localized: "Closes: \(closes.map(String.init).joined(separator: ", "))")) }
            return parts.joined(separator: " · ")
        }()
        if f["firewall"] == "firewalld" || f["firewall"] == "nftables" {
            items.append(Item(id: "firewall", title: String(localized: "Firewall rules"), detail: firewallDetail,
                              state: .notPossible(String(localized: "This server uses \(f["firewall"]); Deckhand sets up ufw only."))))
        } else if f["pm"] != "apt" && f["firewall"] != "ufw" {
            items.append(Item(id: "firewall", title: String(localized: "Firewall rules"), detail: firewallDetail,
                              state: .notPossible(String(localized: "ufw needs apt (Debian or Ubuntu)."))))
        } else {
            items.append(Item(id: "firewall", title: String(localized: "Firewall rules"), detail: firewallDetail,
                              state: .change(firewall(rules), guarded: true)))
        }

        // SSH logins
        let sshFine = f["ssh.password"] == "no" && f["ssh.kbd"] != "yes" && ["no", "prohibit-password", "without-password"].contains(f["ssh.root"])
            && (Int(f["ssh.maxauthtries"]) ?? 6) <= 3
        if sshFine {
            items.append(Item(id: "ssh", title: String(localized: "SSH logins"), detail: String(localized: "Keys only, no root password"), state: .alreadyFine))
        } else if !context.usesKey {
            items.append(Item(id: "ssh", title: String(localized: "SSH logins"), detail: String(localized: "Passwords still allowed"),
                              state: .notPossible(String(localized: "Deckhand logs in with a password here — set up a key first (Edit server → Create a key)."))))
        } else {
            items.append(Item(id: "ssh", title: String(localized: "SSH logins"), detail: String(localized: "Keys only, no root password, 3 tries"),
                              state: .change(Hardening.ssh(context: context, includeEnabled: f["ssh.include"] == "yes"), guarded: true)))
        }

        // Failed-login blocking
        items.append(f["fail2ban"] == "active"
            ? Item(id: "fail2ban", title: String(localized: "Block repeated failed logins"), detail: "fail2ban", state: .alreadyFine)
            : f["pm"] == "apt"
                ? Item(id: "fail2ban", title: String(localized: "Block repeated failed logins"), detail: "fail2ban", state: .change(Hardening.fail2ban(sshPorts: sshPorts), guarded: false))
                : Item(id: "fail2ban", title: String(localized: "Block repeated failed logins"), detail: "fail2ban", state: .notPossible(String(localized: "Installs with apt only."))))

        // Automatic security updates
        if f["pm"] == "apt" {
            items.append(f["autoupdates"] == "yes"
                ? Item(id: "autoupdates", title: String(localized: "Automatic security updates"), detail: "unattended-upgrades", state: .alreadyFine)
                : Item(id: "autoupdates", title: String(localized: "Automatic security updates"), detail: "unattended-upgrades", state: .change(Hardening.unattendedUpgrades, guarded: false)))
        } else {
            items.append(Item(id: "autoupdates", title: String(localized: "Automatic security updates"), detail: f["pm"],
                              state: f["autoupdates"] == "yes" ? .alreadyFine : .notPossible(String(localized: "Set up dnf-automatic on this server."))))
        }
        return Plan(profile: profile, rules: rules, closes: closes, items: items, warnings: warnings)
    }

    /// A ufw rule set from scratch: reset, deny incoming, allow the rules, enable. The old rules are backed up and come
    /// back if the fresh login after enabling fails.
    public static func firewall(_ rules: [Rule]) -> ConfigChange {
        var apply = "command -v ufw >/dev/null 2>&1 || { apt-get update -q >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -q ufw; }\n"
        apply += "ufw --force reset >/dev/null\n"
        apply += "ufw default deny incoming >/dev/null\nufw default allow outgoing >/dev/null\n"
        for r in rules {
            if let src = r.source, isValidSource(src) {
                apply += "ufw allow from \(src) to any port \(r.port) proto tcp >/dev/null\n"
            } else if r.source == nil {
                apply += "ufw allow \(r.port)/tcp >/dev/null\n"
            }
        }
        apply += "ufw --force enable"
        return ConfigChange(
            title: "Set the firewall rules", files: ["/etc/ufw/user.rules", "/etc/ufw/user6.rules", "/etc/ufw/ufw.conf", "/etc/default/ufw"],
            apply: apply, validate: "true",
            reload: "if grep -q '^ENABLED=yes' /etc/ufw/ufw.conf; then ufw --force enable >/dev/null; else ufw --force disable >/dev/null; fi",
            verify: "ufw status | grep -q '^Status: active'", guardSeconds: SSHPort.guardSeconds)
    }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
