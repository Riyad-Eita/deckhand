import Foundation

/// A push for every SSH login that doesn't come from a trusted address: a PAM hook on the server posts
/// user, source, country and time to your ntfy topic. Plus the list of recent logins.
public enum LoginAlerts {
    static let hook = "/usr/local/bin/deckhand-login-alert"
    static let config = "/etc/deckhand/login-alert.conf"
    static let pam = "/etc/pam.d/sshd"
    static let pamLine = "session optional pam_exec.so quiet \(hook)"

    public struct Status: Sendable, Hashable {
        public var enabled: Bool
        public var topicURL: String?
        public var trusted: [String]
        public var logins: [Login]
    }

    public struct Login: Sendable, Hashable, Identifiable {
        public var date: String
        public var user: String
        public var address: String
        public var method: String
        public var id: String { date + user + address }
    }

    /// Root script: whether the hook is on, its settings, and the last successful SSH logins.
    public static let statusScript = #"""
    if grep -qF 'deckhand-login-alert' /etc/pam.d/sshd 2>/dev/null && [ -x /usr/local/bin/deckhand-login-alert ]; then echo '@@enabled'; fi
    [ -f /etc/deckhand/login-alert.conf ] && sed -n 's/^\(TOPIC\|TRUSTED\)=/@@&/p' /etc/deckhand/login-alert.conf
    echo '@@logins'
    { journalctl _COMM=sshd -g 'Accepted ' -n 40 -o short-iso --no-pager -q 2>/dev/null || grep -h 'Accepted ' /var/log/auth.log /var/log/secure 2>/dev/null | tail -n 40; } | tail -n 40
    """#

    public static func parse(_ output: String) -> Status {
        var s = Status(enabled: false, topicURL: nil, trusted: [], logins: [])
        var inLogins = false
        for line in output.split(separator: "\n").map(String.init) {
            if line == "@@enabled" { s.enabled = true; continue }
            if line == "@@logins" { inLogins = true; continue }
            if line.hasPrefix("@@TOPIC=") { s.topicURL = unquote(String(line.dropFirst(8))); continue }
            if line.hasPrefix("@@TRUSTED=") { s.trusted = unquote(String(line.dropFirst(10))).split(separator: " ").map(String.init); continue }
            guard inLogins, let login = parseLogin(line) else { continue }
            s.logins.append(login)
        }
        s.logins.reverse()
        return s
    }

    static func unquote(_ s: String) -> String {
        s.count >= 2 && s.hasPrefix("'") && s.hasSuffix("'") ? String(s.dropFirst().dropLast()) : s
    }

    /// `2026-11-10T16:20:01+0100 host sshd[123]: Accepted publickey for deploy from 203.0.113.9 port 50122 ssh2: …`
    /// or the syslog form `Nov 10 16:20:01 host sshd[123]: Accepted password for …`.
    static func parseLogin(_ line: String) -> Login? {
        guard let r = line.range(of: #"Accepted (\S+) for (\S+) from (\S+)"#, options: .regularExpression) else { return nil }
        let parts = line[r].split(separator: " ").map(String.init)
        let prefix = line[..<r.lowerBound].split(separator: " ")
        let date: String
        if let first = prefix.first, first.contains("T") { date = String(first.prefix(16)).replacingOccurrences(of: "T", with: " ") }
        else { date = prefix.prefix(2).joined(separator: " ") + (prefix.count > 2 ? " " + prefix[2].prefix(5) : "") }
        return Login(date: date, user: parts[3], address: parts[5], method: parts[1])
    }

    static func isAddress(_ s: String) -> Bool { s.range(of: #"^[0-9a-fA-F:.]+(/\d{1,3})?$"#, options: .regularExpression) != nil }

    /// The hook. Runs as root through PAM on every SSH session; never blocks or fails a login.
    static let hookScript = #"""
    #!/bin/sh
    # Deckhand: push a notification for SSH logins from untrusted addresses. Never blocks a login.
    [ "$PAM_TYPE" = open_session ] || exit 0
    [ -r /etc/deckhand/login-alert.conf ] || exit 0
    . /etc/deckhand/login-alert.conf
    for t in $TRUSTED; do [ "$t" = "$PAM_RHOST" ] && exit 0; done
    (
      M="$PAM_USER from $PAM_RHOST"
      if command -v curl >/dev/null 2>&1; then
        C=$(curl -fsS -m 5 "https://ipwho.is/$PAM_RHOST?fields=country" 2>/dev/null | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
        curl -fsS -m 10 -H "Title: SSH login on $(hostname)" -H "Tags: key" -d "$M${C:+ ($C)} at $(date '+%Y-%m-%d %H:%M')" "$TOPIC"
      elif command -v wget >/dev/null 2>&1; then
        wget -q -O- --header="Title: SSH login on $(hostname)" --post-data="$M at $(date '+%Y-%m-%d %H:%M')" "$TOPIC"
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys,urllib.request as u; u.urlopen(u.Request(sys.argv[1], sys.argv[2].encode(), {"Title": sys.argv[3]}), timeout=10)' \
          "$TOPIC" "$M at $(date '+%Y-%m-%d %H:%M')" "SSH login on $(hostname)"
      fi
    ) </dev/null >/dev/null 2>&1 &
    exit 0
    """#

    static func configContent(topic: String, trusted: [String]) -> String {
        ["# Deckhand login alerts", "TOPIC=\(ShellQuote.quote(topic))", "TRUSTED=\(ShellQuote.quote(trusted.joined(separator: " ")))"]
            .map(ShellQuote.quote).joined(separator: " ")
    }

    /// Turns alerts on (or updates the topic and trusted addresses).
    public static func enable(topicURL: String, trusted: [String]) -> ConfigChange? {
        guard topicURL.hasPrefix("https://") || topicURL.hasPrefix("http://"), !topicURL.contains("'") else { return nil }
        let t = trusted.filter(isAddress)
        return ConfigChange(
            title: "Turn on SSH login alerts", files: [pam, hook, config],
            apply: """
            mkdir -p /etc/deckhand
            # The hook needs a way to reach ntfy; most servers have curl, minimal images may not.
            command -v curl >/dev/null 2>&1 || { command -v apt-get >/dev/null 2>&1 && apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl >/dev/null; } || true
            printf '%s\\n' \(ShellQuote.quote(hookScript)) > \(hook)
            chmod 755 \(hook)
            printf '%s\\n' \(configContent(topic: topicURL, trusted: t)) > \(config)
            chmod 600 \(config)
            grep -qF \(ShellQuote.quote(pamLine)) \(pam) || printf '%s\\n' \(ShellQuote.quote(pamLine)) >> \(pam)
            """,
            validate: "sshd -t", guardSeconds: SSHPort.guardSeconds)
    }

    /// Only rewrites the trusted list.
    public static func setTrusted(_ trusted: [String], topicURL: String) -> ConfigChange {
        ConfigChange(
            title: "Update trusted login addresses", files: [config],
            apply: "printf '%s\\n' \(configContent(topic: topicURL, trusted: trusted.filter(isAddress))) > \(config)\nchmod 600 \(config)")
    }

    public static let disable = ConfigChange(
        title: "Turn off SSH login alerts", files: [pam, hook, config],
        apply: "sed -i '/deckhand-login-alert/d' \(pam)\nrm -f \(hook) \(config)", validate: "sshd -t")
}
