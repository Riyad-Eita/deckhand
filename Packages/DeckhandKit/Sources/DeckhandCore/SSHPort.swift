import Foundation

/// Moving SSH to another port without locking yourself out, in two guarded steps:
/// 1. `addPort` — sshd listens on the new port *next to* the old one, the firewall lets it in.
///    The app proves a login on the new port, then confirms.
/// 2. `closeOldPorts` — only the new port is left. The app logs in again, then confirms.
/// Both steps roll back by themselves on the server if the app doesn't confirm in time.
public enum SSHPort {
    public static let guardSeconds = 300
    public static let mainConfig = "/etc/ssh/sshd_config"
    static let socketOverride = "/etc/systemd/system/ssh.socket.d/deckhand-port.conf"

    public enum Firewall: Equatable, Sendable {
        case ufw
        case firewalld(zone: String)
        case none
    }

    /// What the server looks like now. Read with `inspectScript` (as root).
    public struct Inspection: Equatable, Sendable {
        public var ports: [Int]
        /// Config files that contain `Port` lines.
        public var portFiles: [String]
        /// Ubuntu 22.10+: sshd is started by ssh.socket.
        public var socketActivated: Bool
        /// Ubuntu 24.04+: ssh.socket takes its ports from sshd_config by itself.
        public var socketGenerator: Bool
        public var firewall: Firewall
        /// ufw rules that let the current SSH port(s) in, as `rule:action`, e.g. `22/tcp:allow`, `OpenSSH:limit`.
        public var firewallSSHRules: [String]
        public var selinuxEnforcing: Bool
        /// TCP ports something listens on.
        public var listening: Set<Int>
        public var sshdFound: Bool
    }

    public static let inspectScript = #"""
    C=/etc/ssh/sshd_config
    if command -v sshd >/dev/null 2>&1; then echo "sshd=yes"; else echo "sshd=no"; fi
    echo "ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')"
    echo "portfiles=$(grep -lE '^[[:space:]]*Port[[:space:]]' "$C" /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tr '\n' ' ')"
    echo "socket=$(systemctl is-active ssh.socket 2>/dev/null)"
    g=no; for d in /usr/lib/systemd/system-generators /lib/systemd/system-generators; do [ -x "$d/sshd-socket-generator" ] && g=yes; done
    echo "generator=$g"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
      echo "firewall=ufw"
      echo "rules=$(ufw status 2>/dev/null | awk '($2=="ALLOW" || $2=="LIMIT") && $1 !~ /\(v6\)/ {print $1 ":" tolower($2)}' | sort -u | tr '\n' ' ')"
    elif [ "$(systemctl is-active firewalld 2>/dev/null)" = active ]; then
      echo "firewall=firewalld"; echo "zone=$(firewall-cmd --get-default-zone 2>/dev/null)"
    else echo "firewall=none"; fi
    echo "selinux=$(getenforce 2>/dev/null)"
    echo "listening=$(ss -ltnH 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | sort -un | tr '\n' ' ')"
    """#

    public static func parse(_ output: String) -> Inspection {
        var v: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            v[String(line[..<eq])] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        func words(_ k: String) -> [String] { (v[k] ?? "").split(separator: " ").map(String.init) }
        let ports = words("ports").compactMap(Int.init)
        let firewall: Firewall = switch v["firewall"] {
        case "ufw": .ufw
        case "firewalld": .firewalld(zone: v["zone"].flatMap { $0.isEmpty ? nil : $0 } ?? "public")
        default: .none
        }
        let sshRules = words("rules").filter { entry in
            let rule = entry.split(separator: ":").first.map(String.init) ?? entry
            return rule == "OpenSSH" || ports.contains { rule == "\($0)" || rule == "\($0)/tcp" }
        }
        return Inspection(
            ports: ports.isEmpty ? [22] : ports, portFiles: words("portfiles"),
            socketActivated: v["socket"] == "active", socketGenerator: v["generator"] == "yes",
            firewall: firewall, firewallSSHRules: sshRules, selinuxEnforcing: v["selinux"] == "Enforcing",
            listening: Set(words("listening").compactMap(Int.init)), sshdFound: v["sshd"] != "no")
    }

    /// Why a port can't be used, or nil if it's fine.
    public static func problem(with port: Int, on inspection: Inspection) -> String? {
        if port < 1024 || port > 65535 { return "Pick a port between 1024 and 65535." }
        if inspection.ports.contains(port) { return "SSH already uses this port." }
        if inspection.listening.contains(port) { return "Something else on the server already uses this port." }
        if [3306, 5432, 6379, 8080, 8443, 27017].contains(port) { return "This port is commonly used by other services. Pick another one." }
        return nil
    }

    /// A random port that's free and not commonly used.
    public static func suggestion(avoiding inspection: Inspection) -> Int {
        while true {
            let p = Int.random(in: 20000...59999)
            if problem(with: p, on: inspection) == nil { return p }
        }
    }

    // MARK: Changes

    static func files(_ i: Inspection) -> [String] {
        var f = [mainConfig] + i.portFiles.filter { $0 != mainConfig }
        if i.socketActivated && !i.socketGenerator { f.append(socketOverride) }
        switch i.firewall {
        case .ufw: f += ["/etc/ufw/user.rules", "/etc/ufw/user6.rules"]
        case .firewalld(let zone): f.append("/etc/firewalld/zones/\(zone).xml")
        case .none: break
        }
        return f
    }

    /// Comments out every existing `Port` line and puts `ports` at the top of sshd_config
    /// (the top is always global — appending could land inside a `Match` block).
    static func setPorts(_ ports: [Int], _ i: Inspection) -> String {
        let portFiles = ([mainConfig] + i.portFiles.filter { $0 != mainConfig }).map(ShellQuote.quote).joined(separator: " ")
        let header = (["# SSH ports, set by Deckhand"] + ports.map { "Port \($0)" }).map(ShellQuote.quote).joined(separator: " ")
        var s = """
        for f in \(portFiles); do [ -f "$f" ] && sed -i -E 's/^([[:space:]]*Port[[:space:]].*)$/# \\1  # replaced by Deckhand/' "$f"; done
        sed -i '/^# SSH ports, set by Deckhand$/d' \(mainConfig)
        { printf '%s\\n' \(header); cat \(mainConfig); } > \(mainConfig).deckhand-new
        cat \(mainConfig).deckhand-new > \(mainConfig); rm -f \(mainConfig).deckhand-new
        """
        if i.socketActivated && !i.socketGenerator {
            let listen = (["[Socket]", "ListenStream="] + ports.map { "ListenStream=\($0)" }).map(ShellQuote.quote).joined(separator: " ")
            s += "\nmkdir -p \(ShellQuote.quote((socketOverride as NSString).deletingLastPathComponent))"
            s += "\nprintf '%s\\n' \(listen) > \(socketOverride)"
        }
        return s
    }

    static func reload(_ i: Inspection) -> String {
        var s = i.socketActivated
            ? "systemctl daemon-reload && systemctl restart ssh.socket"
            : "systemctl reload ssh 2>/dev/null || systemctl reload sshd"
        switch i.firewall {
        case .ufw: s += "\nufw reload >/dev/null"
        case .firewalld: s += "\nfirewall-cmd --reload >/dev/null"
        case .none: break
        }
        return s
    }

    static func listens(on port: Int) -> String {
        "for i in 1 2 3 4 5; do ss -ltnH | awk '{n=split($4,a,\":\"); print a[n]}' | grep -qx \(port) && exit 0; sleep 1; done; exit 1"
    }

    /// Step 1: sshd listens on `port` next to the current ports; the firewall lets it in.
    public static func addPort(_ port: Int, inspection i: Inspection, guardSeconds: Int = SSHPort.guardSeconds) -> ConfigChange {
        var apply = setPorts(i.ports + [port], i)
        switch i.firewall {
        case .ufw: apply += "\nufw allow \(port)/tcp comment 'SSH (Deckhand)'"
        case .firewalld(let zone): apply += "\nfirewall-cmd --permanent --zone=\(ShellQuote.quote(zone)) --add-port=\(port)/tcp"
        case .none: break
        }
        if i.selinuxEnforcing {
            apply += "\nsemanage port -a -t ssh_port_t -p tcp \(port) 2>/dev/null || semanage port -m -t ssh_port_t -p tcp \(port)"
        }
        return ConfigChange(
            title: "Open SSH port \(port)", files: files(i), apply: apply, validate: "sshd -t",
            reload: reload(i), verify: listens(on: port), guardSeconds: guardSeconds)
    }

    /// Step 2: only `port` is left; firewall rules for the old SSH ports are removed.
    public static func closeOldPorts(keep port: Int, inspection i: Inspection, guardSeconds: Int = SSHPort.guardSeconds) -> ConfigChange {
        var apply = setPorts([port], i)
        let old = i.ports.filter { $0 != port }
        switch i.firewall {
        case .ufw:
            for entry in i.firewallSSHRules {
                let parts = entry.split(separator: ":").map(String.init)
                let rule = parts[0], action = parts.count > 1 && parts[1] == "limit" ? "limit" : "allow"
                if rule == "\(port)" || rule == "\(port)/tcp" { continue }
                apply += "\nufw delete \(action) \(ShellQuote.quote(rule))"
            }
        case .firewalld(let zone):
            let z = ShellQuote.quote(zone)
            apply += "\nfirewall-cmd --permanent --zone=\(z) --remove-service=ssh || true"
            for p in old { apply += "\nfirewall-cmd --permanent --zone=\(z) --remove-port=\(p)/tcp || true" }
        case .none: break
        }
        return ConfigChange(
            title: "Close SSH port \(old.map(String.init).joined(separator: ", "))", files: files(i), apply: apply,
            validate: "sshd -t", reload: reload(i), verify: listens(on: port), guardSeconds: guardSeconds)
    }
}
