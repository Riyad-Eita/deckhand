import Foundation

/// Sets up a fresh server securely: an admin user with sudo and this iPhone's key, then the hardening steps.
/// Root and password logins are only turned off after a key login as the new user has worked.
public enum Provisioning {
    /// What the fresh server looks like (root script, `key=value` lines).
    public static let inspectScript = #"""
    . /etc/os-release 2>/dev/null; echo "os=${PRETTY_NAME:-Linux}"
    pm=none; command -v apt-get >/dev/null 2>&1 && pm=apt; [ $pm = none ] && command -v dnf >/dev/null 2>&1 && pm=dnf
    echo "pm=$pm"
    echo "whoami=$(id -un)"
    echo "swap=$(swapon --show --noheadings 2>/dev/null | wc -l)"
    v=$(systemd-detect-virt -c 2>/dev/null); [ -z "$v" ] && [ -f /proc/user_beancounters ] && v=openvz
    echo "container=${v:-none}"
    echo "memmb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
    echo "diskfreemb=$(df -Pm / | awk 'NR==2{print $4}')"
    echo "ssh.ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')"
    echo "ssh.include=$(grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null && echo yes || echo no)"
    echo "public=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|::1)' | awk '{n=split($0,a,":"); print a[n]}' | sort -un | tr '\n' ' ')"
    fw=none; command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active' && fw=ufw
    [ "$(systemctl is-active firewalld 2>/dev/null)" = active ] && fw=firewalld
    echo "firewall=$fw"
    echo "fail2ban=$(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
    au=no; grep -qsE 'Unattended-Upgrade[[:space:]]+"1"' /etc/apt/apt.conf.d/*auto-upgrades && au=yes; echo "autoupdates=$au"
    echo "timesync=$(timedatectl show -p NTP --value 2>/dev/null)"
    echo "users=$(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd | tr '\n' ' ')"
    """#

    public static func isValidUsername(_ name: String) -> Bool {
        let reserved: Set<String> = ["root", "daemon", "bin", "sys", "sync", "nobody", "admin", "sudo", "ubuntu", "debian", "www-data"]
        return name.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil && !reserved.contains(name)
    }

    /// A strong password for sudo: 4 groups of 5 letters and digits, easy to read out.
    public static func generatePassword() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return (0..<4).map { _ in String((0..<5).map { _ in chars.randomElement()! }) }.joined(separator: "-")
    }

    /// Creates `username` (or updates it), sets its password from stdin, adds it to sudo/wheel and installs `publicKey`.
    /// Root script; send the password as the first `input` line.
    public static func createAdminScript(username: String, publicKey: String) -> String {
        let u = ShellQuote.quote(username)
        let key = ShellQuote.quote(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        return """
        set -e
        U=\(u)
        IFS= read -r PW
        [ -n "$PW" ] || { echo '@@failed password'; exit 1; }
        echo '@@step user'
        id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
        printf '%s:%s\\n' "$U" "$PW" | chpasswd
        if getent group sudo >/dev/null; then usermod -aG sudo "$U"; else usermod -aG wheel "$U"; fi
        echo '@@step key'
        H=$(getent passwd "$U" | cut -d: -f6); G=$(id -gn "$U")
        install -d -m 700 -o "$U" -g "$G" "$H/.ssh"
        touch "$H/.ssh/authorized_keys"
        grep -qxF \(key) "$H/.ssh/authorized_keys" || printf '%s\\n' \(key) >> "$H/.ssh/authorized_keys"
        chown "$U:$G" "$H/.ssh/authorized_keys"; chmod 600 "$H/.ssh/authorized_keys"
        echo '@@done'
        """
    }

    /// Swap file of `megabytes` (helps small servers survive memory spikes). Removed again on rollback.
    public static func swap(megabytes: Int) -> ConfigChange {
        ConfigChange(
            title: "Add \(megabytes) MB of swap", files: ["/etc/fstab"],
            apply: """
            [ -f /swapfile ] || fallocate -l \(megabytes)M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=\(megabytes)
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            """,
            reload: "if grep -q '^/swapfile ' /etc/fstab; then swapon /swapfile 2>/dev/null || swapon --show | grep -q /swapfile; else swapoff /swapfile 2>/dev/null; rm -f /swapfile; fi",
            verify: "swapon --show | grep -q /swapfile")
    }

    /// Swap size for a server with `memoryMB` of RAM: as much as RAM, between 1 and 2 GB.
    public static func swapSize(memoryMB: Int) -> Int { min(2048, max(1024, memoryMB)) }

    public static let timeSyncScript = """
    echo '@@step timesync'
    if ! systemctl list-unit-files 2>/dev/null | grep -qE '^(systemd-timesyncd|chronyd|chrony)\\.service'; then
      if command -v apt-get >/dev/null 2>&1; then apt-get update -q >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -q systemd-timesyncd; fi
    fi
    timedatectl set-ntp true
    echo '@@done'
    """
}
