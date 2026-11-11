import Foundation

/// my-app.example.com → a service on this server, with HTTPS: Caddy as reverse proxy (certificates are automatic),
/// a DNS check before anything is changed, and a list of domains with their certificate status.
public enum Domains {
    /// One file per domain; Caddy imports the folder with a glob (an empty folder is fine, an empty file is not).
    static let dir = "/etc/caddy/deckhand.d"
    static func file(_ name: String) -> String { "\(dir)/\(name).caddy" }
    static let caddyfile = "/etc/caddy/Caddyfile"
    static let begin = "# deckhand-domain "

    public struct Domain: Sendable, Hashable, Identifiable {
        public var name: String
        /// `127.0.0.1:3000` or a URL.
        public var upstream: String
        /// Caddy's own CA instead of Let's Encrypt (internal names, testing).
        public var internalTLS = false
        public var id: String { name }
        public init(name: String, upstream: String, internalTLS: Bool = false) { self.name = name; self.upstream = upstream; self.internalTLS = internalTLS }

        public static func isValidName(_ n: String) -> Bool {
            n.count <= 253 && n.range(of: #"^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$"#, options: .regularExpression) != nil
        }
        public static func isValidUpstream(_ u: String) -> Bool {
            u.range(of: #"^(https?://)?[A-Za-z0-9.\-\[\]:]+:\d{1,5}(/.*)?$"#, options: .regularExpression) != nil
        }

        var block: String {
            """
            \(begin)\(name)
            \(name) {
            \(internalTLS ? "\ttls internal\n" : "")\treverse_proxy \(upstream)
            }
            """
        }
    }

    /// Non-root checks before adding: where the domain points, this server's addresses, and who holds ports 80/443.
    /// Lines: `@@resolves <ip>`, `@@local <ip>`, `@@public <ip>`, `@@port <port> <process>`, `@@caddy yes|no`.
    public static func checkCommand(_ name: String) -> String {
        let n = ShellQuote.quote(name)
        return """
        getent ahosts \(n) 2>/dev/null | awk '{print $1}' | sort -u | sed 's/^/@@resolves /'
        (hostname -I 2>/dev/null || ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1) | tr ' ' '\\n' | grep -v '^$' | sed 's/^/@@local /'
        p=$(curl -fsS -4 -m 5 https://api.ipify.org 2>/dev/null) && echo "@@public $p"
        (ss -tlnpH 2>/dev/null || ss -tlnH 2>/dev/null) | awk '{split($4,a,":"); port=a[length(a)]; if (port=="80"||port=="443") { p=""; if (match($0,/users:\\(\\("[^"]+"/)) p=substr($0,RSTART+9,RLENGTH-10); print "@@port", port, p }}'
        if command -v caddy >/dev/null 2>&1; then echo '@@caddy yes'; else echo '@@caddy no'; fi
        true
        """
    }

    public struct Check: Sendable, Hashable {
        public var resolves: [String] = []
        public var local: [String] = []
        public var publicIP: String?
        public var ports: [(port: Int, process: String)] = []
        public var caddyInstalled = false
        public static func == (a: Check, b: Check) -> Bool { a.resolves == b.resolves && a.local == b.local && a.publicIP == b.publicIP }
        public func hash(into h: inout Hasher) { h.combine(resolves) }

        /// The domain points at this server (one of its addresses, or its public address behind NAT).
        public var dnsOK: Bool { !resolves.isEmpty && resolves.contains { local.contains($0) || $0 == publicIP } }
        /// Something other than Caddy already serves 80/443 (an unknown process counts as a conflict only without Caddy).
        public var conflict: String? {
            let others = ports.filter { !$0.process.isEmpty && $0.process != "caddy" }
            if let o = others.first { return o.process }
            if !caddyInstalled, ports.contains(where: { $0.process.isEmpty }) { return "another web server" }
            return nil
        }
    }

    public static func parseCheck(_ out: String) -> Check {
        var c = Check()
        for line in out.split(separator: "\n").map(String.init) {
            let p = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard let k = p.first else { continue }
            switch k {
            case "@@resolves": if p.count > 1 { c.resolves.append(p[1]) }
            case "@@local": if p.count > 1 { c.local.append(p[1]) }
            case "@@public": c.publicIP = p.count > 1 ? p[1] : nil
            case "@@port": if p.count > 1, let n = Int(p[1]) { c.ports.append((n, p.count > 2 ? p[2] : "")) }
            case "@@caddy": c.caddyInstalled = p.count > 1 && p[1] == "yes"
            default: break
            }
        }
        return c
    }

    static let install = """
    if ! command -v caddy >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y -q caddy >/dev/null
      elif command -v dnf >/dev/null 2>&1; then dnf install -y -q caddy >/dev/null
      else echo 'Install Caddy first: https://caddyserver.com/docs/install'; exit 1; fi
    fi
    mkdir -p \(dir); [ -f \(caddyfile) ] || : > \(caddyfile)
    grep -qxF 'import \(dir)/*.caddy' \(caddyfile) || printf '\\nimport \(dir)/*.caddy\\n' >> \(caddyfile)
    """

    static let reload = "systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || caddy reload --config \(caddyfile) --adapter caddyfile 2>/dev/null || true"
    static let validate = "caddy validate --config \(caddyfile) --adapter caddyfile >/dev/null"

    /// Adds (or replaces) a domain. Root, guarded like every config change.
    public static func addChange(_ d: Domain) -> ConfigChange {
        ConfigChange(
            title: "Serve \(d.name)", files: [file(d.name), caddyfile],
            apply: install + "\nprintf '%s\\n' \(ShellQuote.quote(d.block)) > \(file(d.name))",
            validate: validate, reload: reload,
            verify: "systemctl is-active --quiet caddy 2>/dev/null || pgrep -x caddy >/dev/null")
    }

    public static func removeChange(_ name: String) -> ConfigChange {
        ConfigChange(title: "Stop serving \(name)", files: [file(name)], apply: "rm -f \(file(name))", validate: validate, reload: reload)
    }

    /// Root: the managed domains with certificate issuer/expiry and whether the service behind answers.
    /// Lines: `@@domain <name>\t<upstream>\t<internal 0|1>\t<cert end epoch|->\t<issuer>\t<upstream http code>`.
    public static let statusCommand = """
    [ -d \(dir) ] || exit 0
    command -v caddy >/dev/null 2>&1 && echo "@@caddy $(systemctl is-active caddy 2>/dev/null || echo unknown)"
    for f in \(dir)/*.caddy; do [ -f "$f" ] || continue
      d=$(basename "$f" .caddy); up=$(awk '/reverse_proxy/{print $2; exit}' "$f")
      i=0; grep -q 'tls internal' "$f" && i=1
      c=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$d" 2>/dev/null | openssl x509 -noout -enddate -issuer 2>/dev/null)
      end=$(printf '%s' "$c" | sed -n 's/^notAfter=//p'); iss=$(printf '%s' "$c" | sed -n 's/^issuer=.*O *= *\\([^,]*\\).*/\\1/p')
      [ -z "$iss" ] && iss=$(printf '%s' "$c" | sed -n 's/^issuer=.*CN *= *\\([^,]*\\).*/\\1/p')
      e=-; [ -n "$end" ] && e=$(date -d "$end" +%s 2>/dev/null || echo -)
      case "$up" in http*) u="$up" ;; *) u="http://$up" ;; esac
      code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$u" 2>/dev/null)
      printf '@@domain %s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$d" "$up" "$i" "$e" "${iss:--}" "${code:-000}"
    done
    true
    """

    public struct Status: Sendable, Hashable, Identifiable {
        public var domain: Domain
        public var certificateEnd: Date?
        public var issuer: String
        public var upstreamCode: Int
        public var id: String { domain.name }
        public var upstreamOK: Bool { (200..<500).contains(upstreamCode) }
    }

    public static func parseStatus(_ out: String) -> (caddy: String?, domains: [Status]) {
        var caddy: String?
        var list: [Status] = []
        for line in out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("@@caddy ") { caddy = String(line.dropFirst(8)) }
            guard line.hasPrefix("@@domain ") else { continue }
            let f = line.dropFirst(9).components(separatedBy: "\t")
            guard f.count == 6 else { continue }
            list.append(Status(domain: Domain(name: f[0], upstream: f[1], internalTLS: f[2] == "1"),
                               certificateEnd: Double(f[3]).map { Date(timeIntervalSince1970: $0) },
                               issuer: f[4] == "-" ? "" : f[4], upstreamCode: Int(f[5]) ?? 0))
        }
        return (caddy, list)
    }
}
