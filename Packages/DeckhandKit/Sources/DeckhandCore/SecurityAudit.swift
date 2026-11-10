import Foundation

/// A security check-up of a Linux server: facts gathered as root, turned into a score and a list of
/// traffic-light items, each with a plain explanation and — where it can be done safely — a reversible fix.
public enum SecurityAudit {
    /// Gathers the facts (root script). One `key=value` per line; lists are space- or comma-separated.
    public static let script = #"""
    export LC_ALL=C
    t() { sshd -T 2>/dev/null | awk -v k="$1" '$1==k{print $2; exit}'; }
    echo "ssh.password=$(t passwordauthentication)"
    echo "ssh.kbd=$(t kbdinteractiveauthentication)"
    echo "ssh.root=$(t permitrootlogin)"
    echo "ssh.maxauthtries=$(t maxauthtries)"
    echo "ssh.x11=$(t x11forwarding)"
    echo "ssh.ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')"
    echo "ssh.include=$(grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null && echo yes || echo no)"
    pm=none; command -v apt-get >/dev/null 2>&1 && pm=apt; [ $pm = none ] && command -v dnf >/dev/null 2>&1 && pm=dnf
    echo "pm=$pm"
    fw=none
    if command -v ufw >/dev/null 2>&1; then fw=ufw-inactive; ufw status 2>/dev/null | grep -q '^Status: active' && fw=ufw; fi
    [ "$(systemctl is-active firewalld 2>/dev/null)" = active ] && fw=firewalld
    if [ "$fw" = none ] || [ "$fw" = ufw-inactive ]; then
      n=$(nft list ruleset 2>/dev/null | grep -cE 'drop|reject'); [ "${n:-0}" -gt 0 ] && fw=nftables
    fi
    echo "firewall=$fw"
    echo "fail2ban=$(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
    if [ $pm = apt ]; then
      echo "updates=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst')"
      echo "updates.security=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep '^Inst' | grep -ci security)"
      echo "updates.listage=$(( ($(date +%s) - $(stat -c %Y /var/lib/apt/lists 2>/dev/null || echo 0)) / 86400 ))"
      au=no; grep -qsE 'Unattended-Upgrade[[:space:]]+"1"' /etc/apt/apt.conf.d/*auto-upgrades && dpkg -s unattended-upgrades >/dev/null 2>&1 && au=yes
      echo "autoupdates=$au"
    elif [ $pm = dnf ]; then
      echo "updates=$(dnf -q check-update 2>/dev/null | grep -cE '^[[:alnum:]]')"
      echo "updates.security=$(dnf -q updateinfo list --security 2>/dev/null | wc -l)"
      echo "autoupdates=$(systemctl is-enabled dnf-automatic.timer dnf-automatic-install.timer 2>/dev/null | grep -q enabled && echo yes || echo no)"
    fi
    echo "public=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|::1)' | awk '{n=split($0,a,":"); print a[n]}' | sort -un | tr '\n' ' ')"
    echo "nopasswd=$(grep -rhsE '^[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    echo "emptypw=$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null | tr '\n' ' ')"
    echo "shellusers=$(awk -F: '($7 !~ /(nologin|false|sync|halt|shutdown)$/ && ($3==0 || $3>=1000)){print $1}' /etc/passwd | tr '\n' ' ')"
    echo "worldwritable=$(find /etc /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin -xdev -type f -perm -0002 2>/dev/null | head -n 20 | tr '\n' ' ')"
    if command -v docker >/dev/null 2>&1; then
      echo "dockerpublic=$(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | while IFS='|' read -r n p; do
        printf '%s' "$p" | tr ',' '\n' | grep -E '^ *(0\.0\.0\.0|\[::\]|:::):[0-9]+' | sed -E 's/^ *[^:]*:([0-9]+).*/\1/' | sort -u | sed "s/^/$n:/"
      done | sort -u | tr '\n' ' ')"
    fi
    echo "reboot=$([ -f /var/run/reboot-required ] && echo yes || echo no)"
    echo "timesync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    """#

    public struct Facts: Sendable, Equatable {
        var values: [String: String]
        public subscript(_ key: String) -> String { values[key] ?? "" }
        public func list(_ key: String) -> [String] { self[key].split(separator: " ").map(String.init) }
        public func int(_ key: String) -> Int? { Int(self[key]) }
    }

    public static func parse(_ output: String) -> Facts {
        var v: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            v[String(line[..<eq])] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return Facts(values: v)
    }

    // MARK: Checks

    public enum Level: Int, Sendable, Comparable {
        case bad, warn, good
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Fix: Sendable, Equatable {
        /// A reversible change (preview, backup, rollback).
        case change(ConfigChange, guarded: Bool)
        /// A root script that can't be undone (e.g. installing updates) — confirm first.
        case run(title: String, script: String)
        /// Open the SSH port screen.
        case sshPort
        /// Hand it to an agent with this prompt.
        case agent(String)
    }

    public struct Check: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var level: Level
        /// What was found, in one line.
        public var detail: String
        /// Why it matters, in plain words.
        public var explanation: String
        public var weight: Int
        public var fix: Fix?
        /// Why the fix isn't offered right now (e.g. the app itself still logs in with a password).
        public var fixBlocked: String?
    }

    /// Context from the app that changes what's safe to fix.
    public struct Context: Sendable {
        public var loginUser: String
        /// The app logs in with a key (so turning off passwords can't lock it out).
        public var usesKey: Bool
        public init(loginUser: String, usesKey: Bool) { self.loginUser = loginUser; self.usesKey = usesKey }
    }

    public static let riskyPorts: [Int: String] = [
        3306: "MySQL", 5432: "PostgreSQL", 6379: "Redis", 27017: "MongoDB", 9200: "Elasticsearch",
        11211: "Memcached", 5984: "CouchDB", 2375: "Docker API", 2376: "Docker API", 9000: "PHP-FPM / admin panels",
    ]

    public static func checks(_ f: Facts, context: Context) -> [Check] {
        var out: [Check] = []
        let sshPorts = f.list("ssh.ports").compactMap(Int.init)
        let publicPorts = f.list("public").compactMap(Int.init)
        let pm = f["pm"]

        // SSH logins
        let passwords = f["ssh.password"] == "yes" || f["ssh.kbd"] == "yes"
        let rootLogin = f["ssh.root"]
        let extras = (f.int("ssh.maxauthtries") ?? 6) > 4 || f["ssh.x11"] == "yes"
        let hardening = Hardening.ssh(context: context, includeEnabled: f["ssh.include"] == "yes")
        out.append(Check(
            id: "ssh.password", title: "Password logins over SSH", level: passwords ? .bad : .good,
            detail: passwords ? "Allowed" : "Off — only keys work",
            explanation: "Bots try millions of passwords against every server on the internet. With password logins off, only someone holding your key can get in.",
            weight: 3, fix: passwords ? .change(hardening, guarded: true) : nil,
            fixBlocked: passwords && !context.usesKey ? "Deckhand itself logs in with a password. Switch this server to a key in its settings first, so turning passwords off can't lock you out." : nil))
        out.append(Check(
            id: "ssh.root", title: "Root login", level: rootLogin == "yes" ? .bad : .good,
            detail: rootLogin == "yes" ? "Root can log in with a password" : (rootLogin == "no" ? "Off" : "Only with a key"),
            explanation: "Root is the one account every attacker knows exists. Logging in as a normal user and using sudo leaves a trail and stops password guessing on root.",
            weight: 3, fix: rootLogin == "yes" ? .change(hardening, guarded: true) : nil,
            fixBlocked: rootLogin == "yes" && !context.usesKey && context.loginUser == "root" ? "Deckhand logs in as root with a password. Switch to a key first." : nil))
        out.append(Check(
            id: "ssh.extras", title: "SSH limits", level: extras ? .warn : .good,
            detail: "\(f.int("ssh.maxauthtries") ?? 6) tries per connection · X11 forwarding \(f["ssh.x11"] == "yes" ? "on" : "off")",
            explanation: "Fewer password tries per connection slow down guessing; X11 forwarding is rarely needed on a server and widens the attack surface.",
            weight: 1, fix: extras ? .change(hardening, guarded: true) : nil))
        out.append(Check(
            id: "ssh.port", title: "SSH port", level: sshPorts == [22] ? .warn : .good,
            detail: "Port \(sshPorts.map(String.init).joined(separator: ", "))",
            explanation: "Port 22 gets nearly all automated attacks. Another port doesn't make SSH secure by itself, but it keeps the logs quiet and the noise away.",
            weight: 1, fix: sshPorts == [22] ? .sshPort : nil))

        // Firewall
        let fw = f["firewall"]
        let hasFirewall = ["ufw", "firewalld", "nftables"].contains(fw)
        let keepOpen = Array(Set(sshPorts + publicPorts.filter { riskyPorts[$0] == nil })).sorted()
        out.append(Check(
            id: "firewall", title: "Firewall", level: hasFirewall ? .good : .bad,
            detail: hasFirewall ? "\(fw) is active" : (fw == "ufw-inactive" ? "ufw is installed but off" : "None active"),
            explanation: "A firewall blocks everything you didn't open on purpose — a database or admin panel that listens by accident stays private.",
            weight: 3, fix: hasFirewall ? nil : (pm == "apt" ? .change(Hardening.ufw(open: keepOpen), guarded: true) : .agent("Set up a firewall on this server that allows SSH on port \(sshPorts.map(String.init).joined(separator: ", ")) and the services that are meant to be public (\(keepOpen.map(String.init).joined(separator: ", "))), and blocks everything else. Show me the plan before you change anything."))))

        // Brute force
        let f2b = f["fail2ban"] == "active"
        out.append(Check(
            id: "fail2ban", title: "Blocking repeated failed logins", level: f2b ? .good : .warn,
            detail: f2b ? "fail2ban is running" : "fail2ban isn't running",
            explanation: "fail2ban bans addresses that keep failing to log in, which stops password guessing and keeps logs readable.",
            weight: 2, fix: f2b ? nil : (pm == "apt" ? .change(Hardening.fail2ban(sshPorts: sshPorts), guarded: false) : .agent("Install and enable fail2ban with an sshd jail for port \(sshPorts.map(String.init).joined(separator: ", ")). Show me the plan first."))))

        // Updates
        if pm == "apt" || pm == "dnf" {
            let security = f.int("updates.security") ?? 0
            let all = f.int("updates") ?? 0
            let stale = (f.int("updates.listage") ?? 0) > 7
            out.append(Check(
                id: "updates", title: "Security updates", level: security > 0 ? .bad : (all > 0 || stale ? .warn : .good),
                detail: security > 0 ? "\(security) security updates waiting" : (all > 0 ? "\(all) updates waiting" : (stale ? "Package lists are over a week old" : "Up to date")),
                explanation: "Most break-ins use holes that already have a fix. Installing updates closes them.",
                weight: 2, fix: (security > 0 || all > 0 || stale) ? .run(title: "Install updates", script: Hardening.installUpdates(pm)) : nil))
            let auto = f["autoupdates"] == "yes"
            out.append(Check(
                id: "autoupdates", title: "Automatic security updates", level: auto ? .good : .warn,
                detail: auto ? "On" : "Off",
                explanation: "With automatic security updates the server patches itself every day, even when you don't look.",
                weight: 2, fix: auto ? nil : (pm == "apt" ? .change(Hardening.unattendedUpgrades, guarded: false) : .agent("Turn on automatic security updates with dnf-automatic (security updates only, applied automatically). Show me the plan first."))))
        }

        // Exposed services
        let risky = publicPorts.compactMap { p in riskyPorts[p].map { "\($0) (\(p))" } }
        let others = publicPorts.filter { !sshPorts.contains($0) && riskyPorts[$0] == nil }
        out.append(Check(
            id: "ports", title: "Services open to the internet", level: risky.isEmpty ? .good : .bad,
            detail: risky.isEmpty
                ? (others.isEmpty ? "Only SSH" : "Ports \(others.map(String.init).joined(separator: ", ")) besides SSH")
                : "\(risky.joined(separator: ", ")) listens on all addresses",
            explanation: "Databases and admin APIs should only listen on localhost or a private network. Exposed, they are one weak password away from a data leak.",
            weight: 3, fix: risky.isEmpty ? nil : .agent("These services listen on all network addresses on this server: \(risky.joined(separator: ", ")). Find out which configuration makes them listen publicly and suggest how to bind them to 127.0.0.1 (or a private network) without breaking the apps that use them. Ask me before changing anything.")))

        // Docker publishes ports past the firewall (it writes its own iptables rules).
        let dockerPublic = f.list("dockerpublic")
        if !dockerPublic.isEmpty && hasFirewall {
            let shown = dockerPublic.prefix(6).map { $0.replacingOccurrences(of: ":", with: " → ") }.joined(separator: ", ")
            out.append(Check(
                id: "docker", title: "Docker ports past the firewall", level: dockerPublic.contains { e in riskyPorts.keys.contains { e.hasSuffix(":\($0)") } } ? .bad : .warn,
                detail: shown,
                explanation: "Docker opens published ports itself, before the firewall looks at them — so these are reachable from the internet even if the firewall blocks them. Bind them to 127.0.0.1 if only this server (or a reverse proxy) needs them.",
                weight: 2, fix: .agent("These Docker containers publish ports on all addresses, which bypasses the firewall: \(dockerPublic.joined(separator: ", ")). For each one, find out whether it must be reachable from the internet. For the ones that don't, show me how to bind them to 127.0.0.1 in their compose file or run command (or add DOCKER-USER rules), and restart them only after I agree.")))
        }

        // Accounts
        let empty = f.list("emptypw")
        out.append(Check(
            id: "accounts", title: "Accounts", level: empty.isEmpty ? .good : .bad,
            detail: empty.isEmpty ? "Login shells: \(f.list("shellusers").joined(separator: ", "))" : "No password: \(empty.joined(separator: ", "))",
            explanation: "Every account that can log in is a door. Accounts without a password are an open door.",
            weight: 3, fix: empty.isEmpty ? nil : .agent("These accounts on this server have an empty password: \(empty.joined(separator: ", ")). Lock them (passwd -l) unless they are needed, and tell me what each one is for. Ask me before changing anything.")))
        let nopasswd = f.list("nopasswd")
        if !nopasswd.isEmpty {
            out.append(Check(
                id: "sudoers", title: "sudo without a password", level: .warn,
                detail: "For \(nopasswd.joined(separator: ", "))",
                explanation: "Anyone who gets into such an account is root at once. Fine for automation accounts, risky for people.",
                weight: 1, fix: .agent("These sudoers entries allow sudo without a password: \(nopasswd.joined(separator: ", ")). Explain what each one is for and whether it should require a password. Use visudo -c before saving anything, and ask me first.")))
        }
        let ww = f.list("worldwritable")
        out.append(Check(
            id: "worldwritable", title: "Files anyone can change", level: ww.isEmpty ? .good : .bad,
            detail: ww.isEmpty ? "None in system folders" : "\(ww.count) in system folders",
            explanation: "A system file every user can write is an easy way to become root.",
            weight: 2, fix: ww.isEmpty ? nil : .change(Hardening.removeWorldWrite(ww), guarded: false)))

        // Housekeeping
        if f["reboot"] == "yes" {
            out.append(Check(
                id: "reboot", title: "Restart pending", level: .warn, detail: "Installed updates wait for a restart",
                explanation: "Kernel and library updates only protect you after a restart.", weight: 1, fix: nil))
        }
        if f["timesync"] == "no" {
            out.append(Check(
                id: "timesync", title: "Clock sync", level: .warn, detail: "The clock isn't synchronised",
                explanation: "Logs, certificates and two-factor codes depend on a correct clock.", weight: 1,
                fix: .agent("The clock on this server isn't synchronised. Turn on time synchronisation (systemd-timesyncd or chrony) and check it works. Ask me first.")))
        }
        return out.sorted { $0.level != $1.level ? $0.level < $1.level : $0.weight > $1.weight }
    }

    /// 0–100: good items count fully, warnings half.
    public static func score(_ checks: [Check]) -> Int {
        let total = checks.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        let got = checks.reduce(0.0) { s, c in s + Double(c.weight) * (c.level == .good ? 1 : c.level == .warn ? 0.5 : 0) }
        return Int((got / Double(total) * 100).rounded())
    }
}

/// Reversible hardening steps, shared by the audit and server provisioning.
public enum Hardening {
    static let sshDropIn = "/etc/ssh/sshd_config.d/00-deckhand-hardening.conf"

    static let sshReload = "systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh.socket"

    /// Keys only, no root password login, 3 tries, no X11. sshd uses the first value it reads, so the
    /// settings go into a drop-in that sorts first — or to the top of sshd_config if it has no Include.
    public static func ssh(context: SecurityAudit.Context, includeEnabled: Bool) -> ConfigChange {
        var lines = ["# Hardened by Deckhand"]
        if context.usesKey { lines += ["PasswordAuthentication no", "KbdInteractiveAuthentication no"] }
        lines.append("PermitRootLogin \(context.loginUser == "root" ? "prohibit-password" : "no")")
        lines += ["MaxAuthTries 3", "X11Forwarding no"]
        let body = lines.map(ShellQuote.quote).joined(separator: " ")
        let apply = includeEnabled
            ? "printf '%s\\n' \(body) > \(sshDropIn)"
            : """
            sed -i '/^# Hardened by Deckhand$/,/^X11Forwarding no$/d' /etc/ssh/sshd_config
            { printf '%s\\n' \(body); cat /etc/ssh/sshd_config; } > /etc/ssh/sshd_config.deckhand-new
            cat /etc/ssh/sshd_config.deckhand-new > /etc/ssh/sshd_config; rm -f /etc/ssh/sshd_config.deckhand-new
            """
        return ConfigChange(
            title: "Harden SSH logins", files: ["/etc/ssh/sshd_config", sshDropIn], apply: apply,
            validate: "sshd -t", reload: sshReload, guardSeconds: SSHPort.guardSeconds)
    }

    /// Default-deny ufw that keeps SSH and the given ports open.
    public static func ufw(open ports: [Int]) -> ConfigChange {
        var apply = "command -v ufw >/dev/null 2>&1 || { apt-get update -q >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -q ufw; }\n"
        apply += "ufw default deny incoming\nufw default allow outgoing\n"
        for p in ports { apply += "ufw allow \(p)/tcp\n" }
        apply += "ufw --force enable"
        return ConfigChange(
            title: "Turn on the firewall", files: ["/etc/ufw/user.rules", "/etc/ufw/user6.rules", "/etc/ufw/ufw.conf", "/etc/default/ufw"],
            apply: apply, validate: "true",
            reload: "if grep -q '^ENABLED=yes' /etc/ufw/ufw.conf; then ufw --force enable >/dev/null; else ufw --force disable >/dev/null; fi",
            verify: "ufw status | grep -q '^Status: active'", guardSeconds: SSHPort.guardSeconds)
    }

    static let fail2banJail = "/etc/fail2ban/jail.d/deckhand-sshd.local"

    public static func fail2ban(sshPorts: [Int]) -> ConfigChange {
        let ports = (sshPorts.isEmpty ? [22] : sshPorts).map(String.init).joined(separator: ",")
        let jail = ["[sshd]", "enabled = true", "port = \(ports)", "maxretry = 5", "findtime = 10m", "bantime = 1h"]
            .map(ShellQuote.quote).joined(separator: " ")
        return ConfigChange(
            title: "Block repeated failed logins", files: [fail2banJail],
            apply: """
            command -v fail2ban-client >/dev/null 2>&1 || { apt-get update -q >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -q fail2ban; }
            mkdir -p /etc/fail2ban/jail.d
            printf '%s\\n' \(jail) > \(fail2banJail)
            if [ ! -f /var/log/auth.log ] && command -v journalctl >/dev/null 2>&1; then echo 'backend = systemd' >> \(fail2banJail); fi
            # Web servers get their login and scanner jails too.
            [ -f /var/log/nginx/error.log ] && printf '\\n[nginx-http-auth]\\nenabled = true\\n\\n[nginx-botsearch]\\nenabled = true\\n' >> \(fail2banJail)
            [ -f /var/log/apache2/error.log ] && printf '\\n[apache-auth]\\nenabled = true\\n\\n[apache-badbots]\\nenabled = true\\n' >> \(fail2banJail)
            true
            systemctl enable fail2ban >/dev/null 2>&1 || true
            """,
            validate: "fail2ban-client -t >/dev/null 2>&1 || ! [ -f \(fail2banJail) ]",
            reload: "systemctl restart fail2ban",
            verify: "for i in 1 2 3 4 5; do fail2ban-client status sshd >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1")
    }

    static let autoUpgrades = "/etc/apt/apt.conf.d/20auto-upgrades"

    public static let unattendedUpgrades = ConfigChange(
        title: "Turn on automatic security updates", files: [autoUpgrades],
        apply: """
        dpkg -s unattended-upgrades >/dev/null 2>&1 || { apt-get update -q >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades; }
        printf '%s\\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' > \(autoUpgrades)
        """,
        verify: "apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade \"1\"'")

    public static func removeWorldWrite(_ files: [String]) -> ConfigChange {
        ConfigChange(
            title: "Make system files writable only by their owner", files: files,
            apply: files.map { "chmod o-w \(ShellQuote.quote($0))" }.joined(separator: "\n"))
    }

    public static func installUpdates(_ pm: String) -> String {
        pm == "dnf"
            ? "set -o pipefail; echo '@@step install'; dnf -y upgrade --refresh 2>&1 | tail -n 40; echo '@@done'"
            : """
            set -o pipefail
            export DEBIAN_FRONTEND=noninteractive
            echo '@@step refresh'; apt-get update -q 2>&1 | tail -n 3
            echo '@@step install'; apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade 2>&1 | tail -n 40
            echo '@@done'
            """
    }
}
