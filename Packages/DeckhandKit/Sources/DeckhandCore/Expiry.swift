import Foundation

/// Warnings before certificates or domains expire: a daily cron job on the server reads each domain's certificate
/// (openssl) and registration (RDAP) and pushes at 30, 7 and 1 days left — each step once, reset after a renewal.
public enum Expiry {
    static let dir = "$HOME/.deckhand/expiry"
    static let cronTag = "# deckhand-expiry"
    /// Days left at which a push goes out (descending).
    public static let thresholds = [30, 7, 1]

    /// The registered domain for RDAP: `shop.example.com` → `example.com`, `a.b.example.co.uk` → `example.co.uk`.
    public static func registrable(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let twoLevel: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp",
                                     "com.br", "com.tr", "co.za", "com.mx", "co.in", "com.cn", "com.sg", "co.kr", "com.ar"]
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return labels.suffix(twoLevel.contains(lastTwo) ? 3 : 2).joined(separator: ".")
    }

    public static func isValidDomain(_ s: String) -> Bool { Domains.Domain.isValidName(s.lowercased()) }

    /// Runs daily from cron (FORCE=1 to run now): one line per domain in `status`, pushes at the thresholds.
    static let runner = #"""
    #!/bin/sh
    # Deckhand expiry checks — certificates and domain registrations, daily from cron.
    D="$HOME/.deckhand/expiry"; [ -f "$D/domains" ] || exit 0
    TOPIC=; SERVER=; [ -f "$D/config" ] && . "$D/config"
    now=$(date +%s); out="$D/status.new"; : > "$out"
    epoch() { date -d "$1" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$1" +%s 2>/dev/null || date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null; }
    push() {
      [ -n "$TOPIC" ] || return 0
      curl -fsS -m 10 -H "Title: Deckhand" -H "Tags: $2" -H "Priority: ${3:-default}" -d "$1" "$TOPIC" >/dev/null 2>&1
    }
    warn() { # key what label end
      [ -n "$4" ] || return 0
      left=$(( ($4 - now) / 86400 )); f="$D/state/$1"; last=$(cat "$f" 2>/dev/null || echo 999)
      step=; for t in 1 7 30; do [ "$left" -le "$t" ] && { step=$t; break; }; done
      [ "$left" -lt 0 ] && step=0
      if [ -z "$step" ]; then rm -f "$f"; return 0; fi
      [ "$step" -lt "$last" ] || return 0
      echo "$step" > "$f"
      if [ "$step" = 0 ]; then push "$2 for $3 has expired." rotating_light urgent
      elif [ "$left" -le 1 ]; then push "$2 for $3 expires tomorrow." warning high
      else push "$2 for $3 expires in $left days." warning; fi
    }
    mkdir -p "$D/state"
    T=; command -v timeout >/dev/null 2>&1 && T="timeout 15"
    while read -r d; do
      case "$d" in ''|'#'*) continue ;; esac
      c=$(echo | $T openssl s_client -connect "$d:443" -servername "$d" 2>/dev/null | openssl x509 -noout -enddate -issuer 2>/dev/null)
      cend=$(printf '%s' "$c" | sed -n 's/^notAfter=//p'); ce=; [ -n "$cend" ] && ce=$(epoch "$cend")
      iss=$(printf '%s' "$c" | sed -n 's/^issuer=.*O *= *\([^,]*\).*/\1/p')
      reg=$(cat "$D/reg.$d" 2>/dev/null || echo "$d")
      j=$(curl -fsSL -m 20 -H 'Accept: application/rdap+json' "https://rdap.org/domain/$reg" 2>/dev/null)
      dend=$(printf '%s' "$j" | tr -d '\n' | grep -o '"eventAction" *: *"expiration"[^}]*' | grep -o '"eventDate" *: *"[^"]*"' | head -n 1 | sed 's/.*: *"//; s/"$//')
      [ -z "$dend" ] && dend=$(printf '%s' "$j" | tr -d '\n' | grep -o '"eventDate" *: *"[^"]*" *, *"eventAction" *: *"expiration"' | head -n 1 | sed 's/^"eventDate" *: *"//; s/".*//')
      de=; [ -n "$dend" ] && de=$(epoch "$(printf '%s' "$dend" | sed 's/\.[0-9]*Z$/Z/; s/+00:00$/Z/')")
      printf '%s\t%s\t%s\t%s\t%s\n' "$d" "${ce:--}" "${iss:--}" "${de:--}" "$now" >> "$out"
      warn "$d.cert" "The certificate" "$d" "$ce"
      warn "$reg.domain" "The domain registration" "$reg" "$de"
    done < "$D/domains"
    mv "$out" "$D/status"
    """#

    /// Installs the runner (daily at a random minute after 8:00) and stores the push topic.
    public static func installCommand(topic: String, server: UUID? = nil) -> String {
        let t = topic.contains("'") ? "" : topic
        return """
        mkdir -p \(dir) && chmod 700 \(dir) && touch \(dir)/domains
        printf '%s\\n' \(ShellQuote.quote(runner)) > \(dir)/run.sh && chmod 700 \(dir)/run.sh
        printf 'TOPIC=%s\\nSERVER=%s\\n' \(ShellQuote.quote(ShellQuote.quote(t))) '\(server?.uuidString ?? "")' > \(dir)/config
        command -v crontab >/dev/null 2>&1 || { echo '@@nocron'; exit 0; }
        { crontab -l 2>/dev/null | grep -v 'deckhand/expiry/run.sh'; echo "\(Int.random(in: 0...59)) 8 * * * $HOME/.deckhand/expiry/run.sh >/dev/null 2>&1 \(cronTag)"; } | crontab -
        echo '@@ok'
        """
    }

    public static func addCommand(_ domain: String) -> String {
        let d = domain.lowercased()
        guard isValidDomain(d) else { return "echo '@@failed invalid'" }
        let reg = registrable(d)
        return """
        D=\(dir); mkdir -p "$D" && touch "$D/domains"
        grep -qxF \(ShellQuote.quote(d)) "$D/domains" || echo \(ShellQuote.quote(d)) >> "$D/domains"
        echo \(ShellQuote.quote(reg)) > "$D/reg.\(d)"
        echo '@@ok'
        """
    }

    public static func removeCommand(_ domain: String) -> String {
        let d = domain.lowercased()
        guard isValidDomain(d) else { return "echo '@@failed invalid'" }
        return """
        D=\(dir); [ -f "$D/domains" ] || exit 0
        grep -vxF \(ShellQuote.quote(d)) "$D/domains" > "$D/domains.new"; mv "$D/domains.new" "$D/domains"
        rm -f "$D/reg.\(d)" "$D/state/\(d).cert"
        echo '@@ok'
        """
    }

    public static let runNowCommand = "[ -x \(dir)/run.sh ] && FORCE=1 \(dir)/run.sh; echo '@@ok'"

    public static let uninstallCommand = """
    crontab -l 2>/dev/null | grep -v 'deckhand/expiry/run.sh' | crontab - 2>/dev/null; rm -rf \(dir); echo '@@ok'
    """

    /// Installed?, the domains, their last results, and suggestions (uptime check hosts, Caddy domains, nginx
    /// server names). Lines: `@@installed`, `@@domain <d>`, `@@status <d>\t<cert end|->\t<issuer|->\t<domain end|->\t<checked>`,
    /// `@@suggest <d>`.
    public static let statusCommand = """
    D=\(dir)
    crontab -l 2>/dev/null | grep -q 'deckhand/expiry/run.sh' && echo '@@installed'
    [ -f "$D/domains" ] && sed '/^$/d; s/^/@@domain /' "$D/domains"
    [ -f "$D/status" ] && sed 's/^/@@status /' "$D/status"
    { [ -f "$HOME/.deckhand/uptime/checks.tsv" ] && cut -f3 "$HOME/.deckhand/uptime/checks.tsv" | sed -n 's#^https\\{0,1\\}://\\([^/:]*\\).*#\\1#p'
      ls /etc/caddy/deckhand.d/ 2>/dev/null | sed -n 's/\\.caddy$//p'
      grep -rhoE '^[[:space:]]*server_name[[:space:]]+[^;]+' /etc/nginx/sites-enabled 2>/dev/null | sed 's/^[[:space:]]*server_name[[:space:]]*//' | tr ' ' '\\n'
    } | grep -E '^[a-z0-9.-]+\\.[a-z]{2,}$' | grep -v -e '^localhost' -e '\\.local$' -e '\\.test$' -e '\\.internal$' | sort -u | sed 's/^/@@suggest /' | head -n 40
    true
    """

    public struct Entry: Sendable, Hashable, Identifiable {
        public var domain: String
        public var certificateEnd: Date?
        public var issuer: String
        public var registrationEnd: Date?
        public var checked: Date?
        public var id: String { domain }

        public func daysLeft(_ end: Date?, now: Date = Date()) -> Int? {
            end.map { Int(floor($0.timeIntervalSince(now) / 86_400)) }
        }
    }

    public struct Status: Sendable, Hashable {
        public var installed = false
        public var entries: [Entry] = []
        public var suggestions: [String] = []
    }

    public static func parseStatus(_ out: String) -> Status {
        var s = Status()
        var results: [String: Entry] = [:]
        var order: [String] = []
        for line in out.split(separator: "\n").map(String.init) {
            if line == "@@installed" { s.installed = true }
            else if line.hasPrefix("@@domain ") { order.append(String(line.dropFirst(9))) }
            else if line.hasPrefix("@@suggest ") { s.suggestions.append(String(line.dropFirst(10))) }
            else if line.hasPrefix("@@status ") {
                let f = line.dropFirst(9).components(separatedBy: "\t")
                guard f.count == 5 else { continue }
                func date(_ v: String) -> Date? { Double(v).map { Date(timeIntervalSince1970: $0) } }
                results[f[0]] = Entry(domain: f[0], certificateEnd: date(f[1]), issuer: f[2] == "-" ? "" : f[2],
                                      registrationEnd: date(f[3]), checked: date(f[4]))
            }
        }
        s.entries = order.map { results[$0] ?? Entry(domain: $0, issuer: "") }
        s.suggestions.removeAll { order.contains($0) }
        return s
    }
}
