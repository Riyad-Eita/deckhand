import Foundation

/// The panic button: when a server looks compromised, save the evidence and contain it in one guarded, reversible
/// change — SSH only from your address, passwords and root login off, chosen public services stopped, every other
/// SSH session ended. "All clear" undoes it and starts the services again.
public enum Lockdown {
    public struct Plan: Sendable, Hashable {
        /// Your address as the server sees it (`SSH_CLIENT`); SSH stays open only for it.
        public var myAddress: String
        public var sshPorts: [Int]
        public var onlyMyAddress = true
        public var passwordsOff = true
        public var endOtherSessions = true
        /// systemd units to stop, e.g. `nginx.service`.
        public var stopServices: [String] = []

        public init(myAddress: String, sshPorts: [Int] = [22], onlyMyAddress: Bool = true, passwordsOff: Bool = true,
                    endOtherSessions: Bool = true, stopServices: [String] = []) {
            self.myAddress = myAddress; self.sshPorts = sshPorts; self.onlyMyAddress = onlyMyAddress
            self.passwordsOff = passwordsOff; self.endOtherSessions = endOtherSessions; self.stopServices = stopServices
        }

        /// Restricting SSH needs an IPv4 address (ufw inserts per family).
        public var canRestrict: Bool { myAddress.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil }
    }

    static let sshDropIn = "/etc/ssh/sshd_config.d/00-deckhand-lockdown.conf"
    static let ufwFiles = ["/etc/ufw/user.rules", "/etc/ufw/user6.rules"]
    /// Public-facing services the screen offers to stop.
    public static let stoppable = ["nginx", "apache2", "httpd", "caddy", "docker", "postgresql", "mysql", "mariadb", "redis-server", "mongod", "php8.3-fpm", "php8.2-fpm"]

    public static func evidenceDir(id: String, root: String = ConfigChange.defaultRoot) -> String { "\(root)/\(id)-evidence" }

    /// Copies what an investigator needs, before anything is changed. Read-only apart from the evidence folder.
    static func evidenceScript(_ dir: String) -> String {
        let d = ShellQuote.quote(dir)
        return """
        D=\(d); mkdir -p "$D" && chmod 700 "$D"
        { date -u; uptime; } > "$D/when.txt" 2>&1
        who -a > "$D/who.txt" 2>&1 || true
        last -n 100 -F > "$D/last-logins.txt" 2>&1 || true
        lastb -n 100 > "$D/failed-logins.txt" 2>&1 || true
        ps auxf > "$D/processes.txt" 2>&1 || ps aux > "$D/processes.txt" 2>&1 || true
        (ss -tunap || netstat -tunap) > "$D/connections.txt" 2>&1 || true
        find /etc /tmp /var/tmp /dev/shm /root /home /usr/local/bin /usr/bin -xdev -type f -mmin -1440 2>/dev/null | head -n 500 > "$D/changed-files.txt" || true
        for h in /root /home/*; do [ -f "$h/.ssh/authorized_keys" ] && { echo "== $h"; cat "$h/.ssh/authorized_keys"; }; done > "$D/authorized-keys.txt" 2>&1 || true
        { for u in $(cut -d: -f1 /etc/passwd); do c=$(crontab -l -u "$u" 2>/dev/null) && printf '== %s\\n%s\\n' "$u" "$c"; done; cat /etc/crontab; ls -la /etc/cron.d; } > "$D/cron.txt" 2>&1 || true
        (journalctl -u ssh -u sshd --since -2d --no-pager 2>/dev/null || tail -n 1000 /var/log/auth.log 2>/dev/null) | tail -n 1000 > "$D/ssh-log.txt" || true
        echo "@@evidence $D"
        """
    }

    /// Ends every SSH session except the one this script runs in (its ancestors).
    static let endSessionsScript = #"""
    anc=" "; p=$$
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do anc="$anc$p "; p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); done
    n=0
    for pid in $(pgrep -f '^sshd(-session)?: [^ ]+(@| \[priv\])' 2>/dev/null); do
      case "$anc" in *" $pid "*) ;; *) kill -HUP "$pid" 2>/dev/null && n=$((n + 1));; esac
    done
    echo "@@ended $n"
    """#

    /// The guarded change. `id` is the ConfigChange id (`ConfigChange.makeID`), which also names the evidence folder.
    public static func change(_ plan: Plan, id: String, root: String = ConfigChange.defaultRoot) -> ConfigChange {
        let ev = evidenceDir(id: id, root: root)
        var apply = [evidenceScript(ev)]
        if plan.passwordsOff {
            apply.append("""
            mkdir -p /etc/ssh/sshd_config.d
            printf '%s\\n' '# Deckhand lockdown' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin no' > \(sshDropIn)
            """)
        }
        if plan.onlyMyAddress && plan.canRestrict {
            let ip = plan.myAddress
            let rules = plan.sshPorts.map { p in
                """
                ufw insert 1 allow from \(ip) to any port \(p) proto tcp comment 'deckhand lockdown' >/dev/null
                ufw insert 2 deny \(p)/tcp comment 'deckhand lockdown' >/dev/null 2>&1 || ufw deny \(p)/tcp comment 'deckhand lockdown' >/dev/null
                """
            }.joined(separator: "\n")
            apply.append("""
            if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
            \(rules)
            echo '@@restricted'
            else echo '@@nofirewall'; fi
            """)
        }
        if !plan.stopServices.isEmpty {
            let units = plan.stopServices.filter { $0.range(of: #"^[A-Za-z0-9@._-]+$"#, options: .regularExpression) != nil }
            apply.append(units.map { "systemctl stop \(ShellQuote.quote($0)) && echo \(ShellQuote.quote($0)) >> \(ShellQuote.quote(ev))/stopped.txt" }.joined(separator: "\n"))
        }
        let verify = plan.endOtherSessions ? endSessionsScript.replacingOccurrences(of: #"echo "@@ended $n""#, with: #"echo "$n" > \#(ShellQuote.quote(ev))/ended.txt; echo "@@ended $n""#) : "true"
        return ConfigChange(
            title: "Lockdown", files: [sshDropIn] + ufwFiles, apply: apply.joined(separator: "\n"),
            validate: "sshd -t", reload: "\(Hardening.sshReload); (command -v ufw >/dev/null 2>&1 && ufw reload >/dev/null 2>&1) || true",
            verify: verify, guardSeconds: SSHPort.guardSeconds)
    }

    /// Undoes the lockdown and starts the stopped services again.
    public static func allClearScript(id: String, root: String = ConfigChange.defaultRoot) -> String {
        let ev = ShellQuote.quote(evidenceDir(id: id, root: root))
        return """
        bash \(ShellQuote.quote("\(root)/\(id)/rollback.sh")) || exit 1
        if [ -f \(ev)/stopped.txt ]; then while read -r u; do systemctl start "$u" && echo "@@started $u"; done < \(ev)/stopped.txt; fi
        echo '@@allclear'
        """
    }

    /// What happened, read back after the guarded change (root: the evidence folder is private).
    public static func summaryScript(id: String, root: String = ConfigChange.defaultRoot) -> String {
        let ev = ShellQuote.quote(evidenceDir(id: id, root: root))
        return """
        echo "@@files $(ls \(ev) 2>/dev/null | wc -l | tr -d ' ')"
        echo "@@ended $(cat \(ev)/ended.txt 2>/dev/null || echo 0)"
        [ -f \(ev)/stopped.txt ] && sed 's/^/@@stopped /' \(ev)/stopped.txt
        echo "@@keys $(grep -cvE '^(==|#|$)' \(ev)/authorized-keys.txt 2>/dev/null || echo 0)"
        echo "@@changed $(wc -l < \(ev)/changed-files.txt 2>/dev/null | tr -d ' ')"
        true
        """
    }

    public struct Summary: Sendable, Hashable {
        public var evidenceFiles = 0, endedSessions = 0, authorizedKeys = 0, changedFiles = 0
        public var stopped: [String] = []
    }

    public static func parseSummary(_ out: String) -> Summary {
        var s = Summary()
        for line in out.split(separator: "\n").map(String.init) {
            let p = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard p.count == 2 else { continue }
            switch p[0] {
            case "@@files": s.evidenceFiles = Int(p[1]) ?? 0
            case "@@ended": s.endedSessions = Int(p[1]) ?? 0
            case "@@keys": s.authorizedKeys = Int(p[1]) ?? 0
            case "@@changed": s.changedFiles = Int(p[1]) ?? 0
            case "@@stopped": s.stopped.append(p[1])
            default: break
            }
        }
        return s
    }
}
