import Foundation

/// A read-only map of a server you don't know yet: what runs there, how requests reach it (domain → web server →
/// app), databases, containers, cron jobs, backups, certificates — and a list of risks. Saved as server notes and
/// as a handover document.
public enum ServerXray {
    public struct Port: Sendable, Hashable, Codable {
        public var address: String
        public var port: Int
        public var process: String
        /// Reachable on all interfaces (not only localhost).
        public var isPublic: Bool { !(address.hasPrefix("127.") || address == "[::1]" || address == "::1" || address.hasPrefix("localhost")) }
    }

    public struct Site: Sendable, Hashable, Codable {
        public var server: String
        public var names: [String]
        public var listens: [String]
        /// proxy_pass / reverse_proxy / ProxyPass target.
        public var upstream: String?
        public var root: String?
        public var redirectsToHTTPS = false
        public var tls: Bool { listens.contains { $0.contains("443") || $0.contains("ssl") } || server == "caddy" }
        public var upstreamPort: Int? {
            guard let u = upstream, let r = u.range(of: #":(\d{2,5})"#, options: .regularExpression) else { return nil }
            return Int(u[r].dropFirst())
        }
    }

    public struct Container: Sendable, Hashable, Codable {
        public var name: String, image: String, ports: String, status: String
        public var running: Bool { status.hasPrefix("Up") }
        public func publishes(_ port: Int) -> Bool { ports.contains(":\(port)->") || ports.contains("->\(port)/") }
    }

    public struct Database: Sendable, Hashable, Codable {
        public var kind: String
        public var port: Port
    }

    public struct Risk: Sendable, Hashable, Codable, Identifiable {
        public enum Level: Int, Sendable, Codable, Comparable { case low, medium, high
            public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue } }
        public var id: String { title }
        public var level: Level
        public var title: String
        public var detail: String
    }

    public struct Report: Sendable, Hashable, Codable {
        public var date = Date()
        public var os = "", kernel = "", cpus = 0, memoryMB = 0, uptimeSeconds = 0
        public var diskTotalKB = 0, diskUsedKB = 0
        public var services: [String] = []
        public var ports: [Port] = []
        public var sites: [Site] = []
        public var containers: [Container] = []
        public var cron: [String] = []
        public var backupTools: [String] = []
        public var pendingUpdates: Int?
        public var securityUpdates: Int?
        public var users: [String] = []
        public var authorizedKeys: Int?
        public var certificates: [String: Date] = [:]

        public var databases: [Database] {
            ports.compactMap { p in Self.dbPorts[p.port].map { Database(kind: $0, port: p) } }
                .reduce(into: [Database]()) { acc, d in if !acc.contains(where: { $0.port.port == d.port.port }) { acc.append(d) } }
        }
        static let dbPorts = [5432: "PostgreSQL", 3306: "MySQL", 6379: "Redis", 27017: "MongoDB", 9200: "Elasticsearch", 11211: "Memcached"]

        public var domains: [String] {
            Array(Set(sites.flatMap(\.names).filter { $0.contains(".") && !$0.hasPrefix("*") && $0 != "localhost" })).sorted()
        }

        /// What answers on a site's upstream: a container publishing that port, or the process listening on it.
        public func app(for site: Site) -> String? {
            guard let port = site.upstreamPort else { return site.root.map { "files in \($0)" } }
            if let c = containers.first(where: { $0.publishes(port) }) { return "\(c.name) (container, port \(port))" }
            if let p = ports.first(where: { $0.port == port }) { return p.process.isEmpty ? "port \(port)" : "\(p.process) (port \(port))" }
            return "port \(port) (nothing listening!)"
        }

        public var hasBackups: Bool {
            !backupTools.isEmpty || cron.contains { $0.range(of: #"backup|restic|borg|duplicity|pg_dump|mysqldump|rclone|rsync"#, options: [.regularExpression, .caseInsensitive]) != nil }
        }

        public var risks: [Risk] {
            var out: [Risk] = []
            if !hasBackups {
                out.append(Risk(level: .high, title: String(localized: "No backups found"),
                                detail: String(localized: "No backup tool and no backup cron job. If the disk dies, the data is gone.")))
            }
            for d in databases where d.port.isPublic {
                out.append(Risk(level: .high, title: String(localized: "\(d.kind) is reachable from outside"),
                                detail: String(localized: "It listens on \(d.port.address):\(d.port.port). Bind it to 127.0.0.1 or close the port in the firewall.")))
            }
            for (domain, end) in certificates.sorted(by: { $0.key < $1.key }) {
                let days = Int(end.timeIntervalSince(date) / 86_400)
                if days < 14 {
                    out.append(Risk(level: .high, title: String(localized: "Certificate for \(domain) expires in \(days) days"),
                                    detail: String(localized: "Renew it, or check why automatic renewal isn't working.")))
                } else if days < 30 {
                    out.append(Risk(level: .medium, title: String(localized: "Certificate for \(domain) expires in \(days) days"),
                                    detail: String(localized: "Automatic renewal usually starts 30 days before; keep an eye on it.")))
                }
            }
            for s in sites where !s.tls && !s.redirectsToHTTPS && s.names.contains(where: { $0.contains(".") }) {
                out.append(Risk(level: .medium, title: String(localized: "\(s.names.first ?? "") has no HTTPS"),
                                detail: String(localized: "The site is served over plain HTTP without a redirect.")))
            }
            for s in sites where s.upstreamPort != nil && app(for: s)?.contains("nothing listening") == true {
                out.append(Risk(level: .high, title: String(localized: "\(s.names.first ?? s.server) points to nothing"),
                                detail: String(localized: "\(s.server) forwards to \(s.upstream ?? ""), but nothing listens there.")))
            }
            if let n = pendingUpdates, n > 0 {
                let sec = securityUpdates ?? 0
                out.append(Risk(level: sec > 0 ? .medium : .low, title: sec > 0 ? String(localized: "\(n) updates waiting, \(sec) for security") : String(localized: "\(n) updates waiting"),
                                detail: String(localized: "Install them from Updates in the Server tab.")))
            }
            if diskTotalKB > 0, Double(diskUsedKB) / Double(diskTotalKB) > 0.85 {
                out.append(Risk(level: .medium, title: String(localized: "Disk is \(Int(Double(diskUsedKB) / Double(diskTotalKB) * 100)) % full"),
                                detail: String(localized: "Look at Disk usage in the Server tab for what can go.")))
            }
            let stopped = containers.filter { !$0.running }
            if !stopped.isEmpty {
                out.append(Risk(level: .low, title: String(localized: "\(stopped.count) stopped containers"),
                                detail: stopped.map(\.name).joined(separator: ", ")))
            }
            return out.sorted { $0.level > $1.level }
        }
    }

    /// The probe: read-only, no sudo. Each line is `@@<kind> <data>`.
    public static let probeCommand = #"""
    echo "@@os $( (. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-}") || true)"
    echo "@@kernel $(uname -sr)"
    echo "@@cpus $(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
    echo "@@mem $(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    echo "@@up $(cut -d. -f1 /proc/uptime 2>/dev/null)"
    df -Pk / 2>/dev/null | awk 'NR==2{print "@@disk", $2, $3}'
    command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print "@@svc", $1}'
    (ss -tlnpH 2>/dev/null || ss -tlnH 2>/dev/null) | awk '{p=""; if (match($0, /users:\(\("[^"]+"/)) p=substr($0, RSTART+9, RLENGTH-10); print "@@port", $4, p}'
    for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do [ -r "$f" ] || continue
      grep -nE '^[[:space:]]*(server[[:space:]]*\{|server_name|listen|root|return)|proxy_pass' "$f" | sed "s|^|@@ng $f:|"; done
    for f in /etc/apache2/sites-enabled/*.conf /etc/httpd/conf.d/*.conf; do [ -r "$f" ] || continue
      grep -niE '^[[:space:]]*(<VirtualHost|ServerName|ServerAlias|ProxyPass[[:space:]]|DocumentRoot|Redirect)' "$f" | sed "s|^|@@ap $f:|"; done
    [ -r /etc/caddy/Caddyfile ] && grep -nE '^[^#[:space:]][^{]*\{|reverse_proxy|^[[:space:]]*root' /etc/caddy/Caddyfile | sed 's|^|@@cd |'
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      docker ps -a --format '@@ct {{.Names}}|{{.Image}}|{{.Ports}}|{{.Status}}' 2>/dev/null; fi
    crontab -l 2>/dev/null | grep -vE '^(#|$)' | sed 's/^/@@cron /'
    for f in /etc/crontab /etc/cron.d/*; do [ -r "$f" ] && grep -vE '^(#|$|[A-Z_]+=)' "$f" | sed 's/^/@@cron /'; done
    ls /etc/cron.daily /etc/cron.weekly 2>/dev/null | grep -iE 'backup|restic|borg' | sed 's/^/@@cron /'
    for b in restic borg borgmatic duplicity rclone; do command -v $b >/dev/null 2>&1 && echo "@@bkt $b"; done
    if command -v apt >/dev/null 2>&1; then u=$(apt list --upgradable 2>/dev/null | grep -c upgradable); s=$(apt list --upgradable 2>/dev/null | grep -c -- -security); echo "@@upd $u $s"; fi
    getent passwd 2>/dev/null | awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)$/ {print "@@user", $1}'
    [ -f "$HOME/.ssh/authorized_keys" ] && echo "@@keys $(grep -cvE '^(#|$)' "$HOME/.ssh/authorized_keys")"
    true
    """#

    /// Certificate expiry for each domain, checked from the server itself.
    public static func certCommand(_ domains: [String]) -> String {
        let safe = domains.filter { $0.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil }.prefix(20)
        guard !safe.isEmpty else { return "true" }
        return """
        command -v openssl >/dev/null 2>&1 || exit 0
        for d in \(safe.joined(separator: " ")); do
          e=$(echo | openssl s_client -connect "$d:443" -servername "$d" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
          [ -n "$e" ] && echo "@@cert $d $(date -d "$e" +%s 2>/dev/null || date -j -f '%b %e %T %Y %Z' "$e" +%s 2>/dev/null)"
        done; true
        """
    }

    public static func parse(_ output: String, certificates: String = "") -> Report {
        var r = Report()
        var nginx: [String: [String]] = [:], nginxOrder: [String] = []
        var apache: [String: [String]] = [:], apacheOrder: [String] = []
        var caddy: [String] = []
        for line in (output + "\n" + certificates).components(separatedBy: "\n") {
            guard line.hasPrefix("@@"), let sp = line.firstIndex(of: " ") else { continue }
            let kind = String(line[line.index(line.startIndex, offsetBy: 2)..<sp])
            let rest = String(line[line.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            switch kind {
            case "os": r.os = rest
            case "kernel": r.kernel = rest
            case "cpus": r.cpus = Int(rest) ?? 0
            case "mem": r.memoryMB = Int(rest) ?? 0
            case "up": r.uptimeSeconds = Int(rest) ?? 0
            case "disk":
                let p = rest.split(separator: " ").compactMap { Int($0) }
                if p.count == 2 { r.diskTotalKB = p[0]; r.diskUsedKB = p[1] }
            case "svc": r.services.append(rest)
            case "port":
                let p = rest.split(separator: " ", maxSplits: 1).map(String.init)
                guard let addr = p.first, let colon = addr.lastIndex(of: ":"), let port = Int(addr[addr.index(after: colon)...]) else { continue }
                let host = String(addr[..<colon])
                if !r.ports.contains(where: { $0.port == port && $0.address == host }) {
                    r.ports.append(Port(address: host, port: port, process: p.count > 1 ? p[1] : ""))
                }
            case "ng", "ap":
                // <file>:<line>:<text>
                let parts = rest.split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                if kind == "ng" { if nginx[parts[0]] == nil { nginxOrder.append(parts[0]) }; nginx[parts[0], default: []].append(parts[2]) }
                else { if apache[parts[0]] == nil { apacheOrder.append(parts[0]) }; apache[parts[0], default: []].append(parts[2]) }
            case "cd": caddy.append(rest.split(separator: ":", maxSplits: 1).last.map(String.init) ?? rest)
            case "ct":
                let f = rest.components(separatedBy: "|")
                if f.count >= 4 { r.containers.append(Container(name: f[0], image: f[1], ports: f[2], status: f[3])) }
            case "cron":
                // Deckhand's own jobs and the distribution's housekeeping are noise here.
                if rest.range(of: #"deckhand-|run-parts|anacron|e2scrub|debian-sa1|/usr/lib/php/sessionclean"#, options: .regularExpression) == nil { r.cron.append(rest) }
            case "bkt": r.backupTools.append(rest)
            case "upd":
                let p = rest.split(separator: " ").compactMap { Int($0) }
                r.pendingUpdates = p.first; r.securityUpdates = p.count > 1 ? p[1] : nil
            case "user": r.users.append(rest)
            case "keys": r.authorizedKeys = Int(rest)
            case "cert":
                let p = rest.split(separator: " ")
                if p.count == 2, let t = Double(p[1]) { r.certificates[String(p[0])] = Date(timeIntervalSince1970: t) }
            default: break
            }
        }
        for f in nginxOrder { r.sites += nginxSites(nginx[f] ?? []) }
        for f in apacheOrder { r.sites += apacheSites(apache[f] ?? []) }
        r.sites += caddySites(caddy)
        return r
    }

    static func value(_ line: String, after key: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix(key.lowercased()) { s = String(s.dropFirst(key.count)) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " \t;"))
    }

    static func nginxSites(_ lines: [String]) -> [Site] {
        var sites: [Site] = []
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("server") && l.contains("{") && !l.hasPrefix("server_name") {
                sites.append(Site(server: "nginx", names: [], listens: [], upstream: nil, root: nil)); continue
            }
            guard !sites.isEmpty else { continue }
            let i = sites.count - 1
            if l.hasPrefix("server_name") { sites[i].names += value(l, after: "server_name").split(separator: " ").map(String.init).filter { $0 != "_" } }
            else if l.hasPrefix("listen") { sites[i].listens.append(value(l, after: "listen")) }
            else if let r = l.range(of: "proxy_pass"), sites[i].upstream == nil {
                sites[i].upstream = l[r.upperBound...].split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
            }
            else if l.hasPrefix("root"), sites[i].root == nil { sites[i].root = value(l, after: "root") }
            else if l.hasPrefix("return"), l.contains("https://") { sites[i].redirectsToHTTPS = true }
        }
        // A plain-HTTP block that only redirects belongs to the HTTPS block of the same name.
        return sites.filter { s in !(s.redirectsToHTTPS && s.upstream == nil && s.root == nil && sites.contains(where: { o in o.tls && !Set(o.names).isDisjoint(with: s.names) })) }
    }

    static func apacheSites(_ lines: [String]) -> [Site] {
        var sites: [Site] = []
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.lowercased().hasPrefix("<virtualhost") {
                let listen = l.dropFirst(12).trimmingCharacters(in: CharacterSet(charactersIn: " >"))
                sites.append(Site(server: "apache", names: [], listens: [listen], upstream: nil, root: nil)); continue
            }
            guard !sites.isEmpty else { continue }
            let i = sites.count - 1, low = l.lowercased()
            if low.hasPrefix("servername") || low.hasPrefix("serveralias") { sites[i].names += l.split(separator: " ").dropFirst().map(String.init) }
            else if low.hasPrefix("proxypass "), sites[i].upstream == nil { sites[i].upstream = l.split(separator: " ").last.map(String.init) }
            else if low.hasPrefix("documentroot") { sites[i].root = l.split(separator: " ").last.map(String.init) }
            else if low.hasPrefix("redirect"), l.contains("https://") { sites[i].redirectsToHTTPS = true }
        }
        return sites
    }

    static func caddySites(_ lines: [String]) -> [Site] {
        var sites: [Site] = []
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasSuffix("{"), !l.hasPrefix("reverse_proxy"), !l.hasPrefix("root") {
                let names = l.dropLast().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter { !$0.isEmpty }
                sites.append(Site(server: "caddy", names: names, listens: ["443"], upstream: nil, root: nil))
            } else if l.hasPrefix("reverse_proxy"), !sites.isEmpty {
                sites[sites.count - 1].upstream = l.split(separator: " ").dropFirst().first.map(String.init)
            } else if l.hasPrefix("root"), !sites.isEmpty {
                sites[sites.count - 1].root = l.split(separator: " ").last.map(String.init)
            }
        }
        return sites
    }

    /// A handover document to share or keep as server notes.
    public static func markdown(_ r: Report, serverName: String) -> String {
        var md = "# \(serverName)\n\n"
        md += "Scanned \(r.date.formatted(date: .abbreviated, time: .shortened)). \(r.os.isEmpty ? r.kernel : r.os), \(r.cpus) CPU, \(r.memoryMB / 1024 > 0 ? "\(r.memoryMB / 1024) GB" : "\(r.memoryMB) MB") memory"
        if r.diskTotalKB > 0 { md += ", disk \(r.diskUsedKB * 100 / r.diskTotalKB) % used of \(r.diskTotalKB / 1_048_576) GB" }
        md += ".\n\n"
        if !r.sites.isEmpty {
            md += "## How requests flow\n"
            for s in r.sites {
                md += "- \(s.names.isEmpty ? "(default)" : s.names.joined(separator: ", ")) → \(s.server)\(s.tls ? " (HTTPS)" : "") → \(r.app(for: s) ?? "—")\n"
            }
            md += "\n"
        }
        if !r.databases.isEmpty { md += "## Databases\n" + r.databases.map { "- \($0.kind) on \($0.port.address):\($0.port.port)\($0.port.isPublic ? " (public!)" : "")" }.joined(separator: "\n") + "\n\n" }
        if !r.containers.isEmpty { md += "## Containers\n" + r.containers.map { "- \($0.name): \($0.image), \($0.status)" }.joined(separator: "\n") + "\n\n" }
        if !r.cron.isEmpty { md += "## Cron jobs\n" + r.cron.prefix(30).map { "- `\($0)`" }.joined(separator: "\n") + "\n\n" }
        md += "## Backups\n" + (r.hasBackups ? "- " + (r.backupTools.isEmpty ? "backup cron job found" : r.backupTools.joined(separator: ", ")) : "- none found") + "\n\n"
        if !r.certificates.isEmpty { md += "## Certificates\n" + r.certificates.sorted { $0.key < $1.key }.map { "- \($0.key): until \($0.value.formatted(date: .abbreviated, time: .omitted))" }.joined(separator: "\n") + "\n\n" }
        let risks = r.risks
        md += "## Risks\n" + (risks.isEmpty ? "- none found" : risks.map { "- \($0.level == .high ? "HIGH" : $0.level == .medium ? "medium" : "low"): \($0.title). \($0.detail)" }.joined(separator: "\n")) + "\n\n"
        if !r.services.isEmpty { md += "## Running services\n" + r.services.joined(separator: ", ") + "\n" }
        return md
    }

    static let begin = "<!-- deckhand:xray -->"
    static let end = "<!-- /deckhand:xray -->"

    /// Puts the X-ray into the server notes (replacing the previous one), so every agent knows the map.
    public static func saveToNotesCommand(_ markdown: String) -> String {
        let block = "\(begin)\n## Server map (Deckhand X-ray)\n\(markdown.replacingOccurrences(of: "\n# ", with: "\n### "))\n\(end)\n"
        let b64 = Data(block.utf8).base64EncodedString()
        return """
        mkdir -p ~/.deckhand && chmod 700 ~/.deckhand && f=\(ServerMemory.path); touch "$f"
        awk -v b=\(ShellQuote.quote(begin)) -v e=\(ShellQuote.quote(end)) '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$f" > "$f.dh" && cat "$f.dh" > "$f" && rm -f "$f.dh"
        printf '%s' '\(b64)' | base64 -d >> "$f" && chmod 600 "$f" && echo '@@ok'
        """
    }

    /// What changed since the previous scan (services, sites, ports, containers), in plain lines.
    public static func changes(from old: Report, to new: Report) -> [String] {
        func diff(_ label: String, _ a: [String], _ b: [String]) -> [String] {
            let sa = Set(a), sb = Set(b)
            return sb.subtracting(sa).sorted().map { "+ \(label): \($0)" } + sa.subtracting(sb).sorted().map { "− \(label): \($0)" }
        }
        return diff(String(localized: "service"), old.services, new.services)
            + diff(String(localized: "site"), old.sites.flatMap(\.names), new.sites.flatMap(\.names))
            + diff(String(localized: "port"), old.ports.map { "\($0.address):\($0.port)" }, new.ports.map { "\($0.address):\($0.port)" })
            + diff(String(localized: "container"), old.containers.map(\.name), new.containers.map(\.name))
    }
}
