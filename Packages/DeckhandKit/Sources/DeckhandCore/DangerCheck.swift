import Foundation

/// Spots tool calls that can destroy data or lock the user out. These always need the user's OK,
/// whatever the approval policy says.
public enum DangerCheck {
    struct Rule {
        let pattern: String
        let reason: String
    }

    static let commandRules: [Rule] = [
        Rule(pattern: #"\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*\s+)*(-[a-zA-Z]*\s+)*(/|~|\$HOME|/\*|\*|\.\*?)(\s|$|/\*)"#, reason: "Deletes a whole directory tree such as / or your home folder."),
        Rule(pattern: #"\brm\s+-[a-zA-Z]*[rR][a-zA-Z]*f|\brm\s+-[a-zA-Z]*f[a-zA-Z]*[rR]"#, reason: "Force-deletes files recursively."),
        Rule(pattern: #"\bmkfs(\.\w+)?\b|\bwipefs\b"#, reason: "Formats a disk."),
        Rule(pattern: #"\bdd\b[^|;&]*\bof=/dev/"#, reason: "Writes raw data onto a device."),
        Rule(pattern: #">\s*/dev/(sd|nvme|vd|xvd)"#, reason: "Overwrites a disk device."),
        Rule(pattern: #"(^|[;&|(]\s*|\bsudo\s+|\bsystemctl\s+)(shutdown|poweroff|halt|reboot)\b|(^|[;&|]\s*|\bsudo\s+)init\s+[06]\b"#, reason: "Shuts down or restarts the server."),
        Rule(pattern: #"(?i)\bdrop\s+(database|schema|table)\b"#, reason: "Deletes a database or table."),
        Rule(pattern: #"(?i)\btruncate\s+(table\s+)?\w+"#, reason: "Empties a database table."),
        Rule(pattern: #"(?i)\bdelete\s+from\s+\w+\s*(;|$)"#, reason: "Deletes every row of a table."),
        Rule(pattern: #"\bgit\s+push\b[^;&|]*(--force\b|-f\b|--force-with-lease)"#, reason: "Overwrites history on the remote."),
        Rule(pattern: #"\bgit\s+reset\s+--hard\b"#, reason: "Throws away uncommitted changes."),
        Rule(pattern: #"\bgit\s+clean\s+-[a-zA-Z]*f"#, reason: "Deletes untracked files."),
        Rule(pattern: #"\bchmod\s+(-R\s+)?[0-7]*777\s+/(\s|$)|\bchown\s+-R\b[^;&|]*\s/(\s|$)"#, reason: "Changes permissions of the whole system."),
        Rule(pattern: #":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, reason: "Fork bomb."),
        Rule(pattern: #"\bdocker\s+(system|volume|image)\s+prune\b[^;&|]*-a|\bdocker\s+volume\s+rm\b"#, reason: "Deletes Docker data."),
        Rule(pattern: #"\bkubectl\s+delete\b"#, reason: "Deletes Kubernetes resources."),
        Rule(pattern: #"\bsystemctl\s+(stop|disable|mask)\s+(ssh|sshd)\b"#, reason: "Can lock you out of SSH."),
        Rule(pattern: #"\b(iptables\s+-F|ufw\s+(enable|reset)|nft\s+flush)\b"#, reason: "Changes the firewall; can lock you out."),
        Rule(pattern: #"\b(userdel|deluser|passwd\s+-l)\b"#, reason: "Removes or locks a user account."),
        Rule(pattern: #"\bcrontab\s+-r\b"#, reason: "Deletes all cron jobs."),
        Rule(pattern: #"authorized_keys"#, reason: "Touches SSH access keys."),
    ]

    static let protectedPaths = ["/etc/", "/boot/", "/usr/", "/bin/", "/sbin/", "/lib", "/var/lib/", "~/.ssh/", "/root/"]

    /// A short explanation if the call is dangerous, otherwise nil.
    public static func assess(_ call: ToolCall) -> String? {
        switch call.name {
        case "run_command":
            guard let command = call.input["command"]?.stringValue else { return nil }
            return assess(command: command)
        case "write_file", "edit_file":
            guard let path = call.input["path"]?.stringValue else { return nil }
            if path.hasSuffix("authorized_keys") || path.hasSuffix("sshd_config") { return "Changes SSH access." }
            if protectedPaths.contains(where: { path.hasPrefix($0) }) { return "Changes a system file (\(path))." }
            return nil
        default:
            return nil
        }
    }

    public static func assess(command: String) -> String? {
        for rule in commandRules where command.range(of: rule.pattern, options: .regularExpression) != nil {
            return rule.reason
        }
        return nil
    }
}
