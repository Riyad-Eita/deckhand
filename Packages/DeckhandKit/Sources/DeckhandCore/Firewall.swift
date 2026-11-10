import Foundation

/// Firewall rules (ufw or firewalld) as a list, with guarded changes that never close the SSH port in use.
public enum Firewall {
    public enum Kind: String, Sendable { case ufw, firewalld, none }

    public struct Rule: Sendable, Hashable, Identifiable {
        /// ufw rule number, or the firewalld item (`service:http`, `port:8080/tcp`).
        public var id: String
        public var target: String
        public var action: String
        public var from: String
        public var comment: String?
        public var ipv6: Bool

        /// The port numbers this rule opens (empty for services/apps we can't map).
        public var ports: [Int] {
            let head = target.split(separator: "/").first.map(String.init) ?? target
            if let p = Int(head) { return [p] }
            let range = head.split(separator: ":").compactMap { Int($0) }
            if range.count == 2, range[0] <= range[1], range[1] - range[0] < 1000 { return Array(range[0]...range[1]) }
            switch target.lowercased() {
            case "openssh", "ssh", "service:ssh": return [22]
            case "service:http", "nginx http", "apache": return [80]
            case "service:https", "nginx https", "apache secure": return [443]
            case "nginx full", "apache full": return [80, 443]
            default: return []
            }
        }
    }

    public struct Status: Sendable, Hashable {
        public var kind: Kind
        public var active: Bool
        public var zone: String?
        public var rules: [Rule]
        /// Ports sshd listens on (may differ from the port the app dials, e.g. behind port forwarding).
        public var sshPorts: [Int] = [22]
    }

    public static let statusScript = #"""
    echo "@@sshports $(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
      echo '@@ufw active'; ufw status numbered 2>/dev/null
    elif [ "$(systemctl is-active firewalld 2>/dev/null)" = active ]; then
      z=$(firewall-cmd --get-default-zone 2>/dev/null); echo "@@firewalld active $z"
      echo "services=$(firewall-cmd --zone="$z" --list-services 2>/dev/null)"
      echo "ports=$(firewall-cmd --zone="$z" --list-ports 2>/dev/null)"
    elif command -v ufw >/dev/null 2>&1; then echo '@@ufw inactive'
    else echo '@@none'; fi
    """#

    public static func parse(_ output: String) -> Status {
        let lines = output.split(separator: "\n").map(String.init)
        let ssh = lines.first { $0.hasPrefix("@@sshports") }.map { $0.split(separator: " ").dropFirst().compactMap { Int($0) } } ?? []
        let sshPorts = ssh.isEmpty ? [22] : ssh
        guard let head = lines.first(where: { $0.hasPrefix("@@") && !$0.hasPrefix("@@sshports") }) else {
            return Status(kind: .none, active: false, rules: [], sshPorts: sshPorts)
        }
        let parts = head.dropFirst(2).split(separator: " ").map(String.init)
        switch parts.first {
        case "ufw":
            var rules: [Rule] = []
            let pattern = #"^\[\s*(\d+)\]\s+(.+?)\s{2,}(ALLOW|DENY|REJECT|LIMIT)(?: IN| OUT| FWD)?\s+(.+?)(?:\s+#\s*(.*))?$"#
            let regex = try? NSRegularExpression(pattern: pattern)
            for line in lines {
                let ns = line as NSString
                guard let m = regex?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)).trimmingCharacters(in: .whitespaces) }
                var target = g(2) ?? ""
                let v6 = target.hasSuffix("(v6)")
                target = target.replacingOccurrences(of: " (v6)", with: "")
                rules.append(Rule(id: g(1) ?? "", target: target, action: g(3) ?? "", from: (g(4) ?? "").replacingOccurrences(of: " (v6)", with: ""),
                                  comment: g(5), ipv6: v6))
            }
            return Status(kind: .ufw, active: parts.count > 1 && parts[1] == "active", rules: rules, sshPorts: sshPorts)
        case "firewalld":
            var rules: [Rule] = []
            for line in lines {
                if line.hasPrefix("services=") {
                    rules += line.dropFirst(9).split(separator: " ").map { Rule(id: "service:\($0)", target: "service:\($0)", action: "ALLOW", from: "Anywhere", ipv6: false) }
                } else if line.hasPrefix("ports=") {
                    rules += line.dropFirst(6).split(separator: " ").map { Rule(id: "port:\($0)", target: String($0), action: "ALLOW", from: "Anywhere", ipv6: false) }
                }
            }
            return Status(kind: .firewalld, active: true, zone: parts.count > 2 ? parts[2] : "public", rules: rules, sshPorts: sshPorts)
        default:
            return Status(kind: .none, active: false, rules: [], sshPorts: sshPorts)
        }
    }

    // MARK: Changes

    public enum Proto: String, Sendable, CaseIterable { case tcp, udp }

    public struct NewRule: Sendable, Hashable {
        public var port: String
        public var proto: Proto
        /// An address or network (`203.0.113.4`, `10.0.0.0/8`); nil for anyone.
        public var from: String?
        public var comment: String
        public init(port: String, proto: Proto = .tcp, from: String? = nil, comment: String) {
            self.port = port; self.proto = proto; self.from = from; self.comment = comment
        }

        /// `80`, `80,443` or a range `6000:6007`.
        public var isValid: Bool {
            let parts = port.split(separator: ",", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 15 else { return false }
            for part in parts {
                let p = part.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
                guard !p.isEmpty, p.count <= 2, p.allSatisfy({ $0 != nil && (1...65535).contains($0!) }) else { return false }
            }
            if let from, !from.isEmpty { return from.range(of: #"^[0-9a-fA-F:.]+(/\d{1,3})?$"#, options: .regularExpression) != nil }
            return true
        }
    }

    static func files(_ s: Status) -> [String] {
        switch s.kind {
        case .ufw: ["/etc/ufw/user.rules", "/etc/ufw/user6.rules"]
        case .firewalld: ["/etc/firewalld/zones/\(s.zone ?? "public").xml"]
        case .none: []
        }
    }

    static func reload(_ s: Status) -> String {
        s.kind == .firewalld ? "firewall-cmd --reload >/dev/null" : "ufw reload >/dev/null"
    }

    public static func add(_ rule: NewRule, to s: Status) -> ConfigChange {
        let port = rule.port.replacingOccurrences(of: "-", with: ":")
        let apply: String
        switch s.kind {
        case .firewalld:
            let z = ShellQuote.quote(s.zone ?? "public")
            if let from = rule.from, !from.isEmpty {
                apply = port.split(separator: ",").map { p in
                    let r = "rule family=\(from.contains(":") ? "ipv6" : "ipv4") source address=\(from) port port=\(p.replacingOccurrences(of: ":", with: "-")) protocol=\(rule.proto.rawValue) accept"
                    return "firewall-cmd --permanent --zone=\(z) --add-rich-rule=\(ShellQuote.quote(r))"
                }.joined(separator: "\n")
            } else {
                apply = port.split(separator: ",").map {
                    "firewall-cmd --permanent --zone=\(z) --add-port=\($0.replacingOccurrences(of: ":", with: "-"))/\(rule.proto.rawValue)"
                }.joined(separator: "\n")
            }
        default:
            let c = rule.comment.isEmpty ? "" : " comment \(ShellQuote.quote(rule.comment))"
            if let from = rule.from, !from.isEmpty {
                apply = "ufw allow from \(ShellQuote.quote(from)) to any port \(port) proto \(rule.proto.rawValue)\(c)"
            } else {
                apply = "ufw allow \(port)/\(rule.proto.rawValue)\(c)"
            }
        }
        let who = rule.from.flatMap { $0.isEmpty ? nil : $0 }.map { " from \($0)" } ?? ""
        return ConfigChange(title: "Allow port \(rule.port)\(who)", files: files(s), apply: apply, reload: reload(s),
                            guardSeconds: SSHPort.guardSeconds)
    }

    /// Why a rule can't be removed (it's how SSH is reached), or nil. Checks every port sshd listens on.
    public static func protects(_ rule: Rule, in s: Status) -> String? {
        guard rule.action != "DENY", rule.action != "REJECT" else { return nil }
        for port in s.sshPorts where rule.ports.contains(port) {
            let others = s.rules.filter {
                $0.target != rule.target && $0.ipv6 == rule.ipv6 && $0.ports.contains(port)
                    && ($0.action == "ALLOW" || $0.action == "LIMIT") && $0.from == "Anywhere"
            }
            if others.isEmpty { return "This rule lets you reach SSH on port \(port). Removing it would lock you out." }
        }
        return nil
    }

    public static func remove(_ rule: Rule, from s: Status) -> ConfigChange {
        let apply: String
        switch s.kind {
        case .firewalld:
            let z = ShellQuote.quote(s.zone ?? "public")
            apply = rule.id.hasPrefix("service:")
                ? "firewall-cmd --permanent --zone=\(z) --remove-service=\(ShellQuote.quote(String(rule.id.dropFirst(8))))"
                : "firewall-cmd --permanent --zone=\(z) --remove-port=\(ShellQuote.quote(String(rule.id.dropFirst(5))))"
        default:
            // ufw keeps IPv4 and IPv6 as separate numbered rules: remove the twin too, higher number first
            // (deleting renumbers the rest).
            let twins = s.rules.filter { $0.target == rule.target && $0.action == rule.action && $0.from == rule.from }
            apply = twins.compactMap { Int($0.id) }.sorted(by: >).map { "ufw --force delete \($0)" }.joined(separator: "\n")
        }
        return ConfigChange(title: "Remove firewall rule \(rule.target)", files: files(s), apply: apply, reload: reload(s),
                            guardSeconds: SSHPort.guardSeconds)
    }

    // MARK: Outside check

    /// Ports worth trying from outside, with what usually listens there.
    public static let wellKnown: [Int: String] = [
        21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 80: "HTTP", 110: "POP3", 143: "IMAP", 443: "HTTPS",
        445: "SMB", 465: "SMTPS", 587: "Mail submission", 993: "IMAPS", 995: "POP3S", 1433: "SQL Server", 2375: "Docker API",
        2376: "Docker API (TLS)", 3000: "Dev server / Grafana", 3306: "MySQL", 3389: "Remote Desktop", 5000: "Dev server",
        5432: "PostgreSQL", 5672: "RabbitMQ", 5900: "VNC", 6379: "Redis", 8000: "Dev server", 8080: "HTTP (alt)",
        8443: "HTTPS (alt)", 9000: "Admin panel / PHP-FPM", 9090: "Prometheus / Cockpit", 9200: "Elasticsearch",
        11211: "Memcached", 27017: "MongoDB",
    ]

    public enum Exposure: Sendable, Equatable {
        /// Open on purpose (SSH, web).
        case expected
        /// Open, and usually shouldn't be.
        case risky
        /// Open, unclear.
        case review
    }

    public static func exposure(port: Int, sshPort: Int) -> Exposure {
        if port == sshPort || [80, 443].contains(port) { return .expected }
        if SecurityAudit.riskyPorts[port] != nil || [21, 23, 445, 3389, 5900, 1433].contains(port) { return .risky }
        return .review
    }
}
