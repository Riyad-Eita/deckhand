import Foundation

/// Copies files from one server straight to another (not through the phone): the source gets a transfer key, the
/// target accepts it for the duration of the copy, rsync runs on the source with `--partial` (a retry resumes), and
/// the target's host key is the one pinned in the app — no trust-on-first-use. The key is removed afterwards.
public enum ServerCopy {
    static let dir = "$HOME/.deckhand/transfer"

    public struct Target: Sendable, Hashable {
        public var host: String
        public var port: Int
        public var user: String
        /// The OpenSSH public key line the app pinned for the target (`ssh-ed25519 AAAA…`).
        public var hostKey: String
        public init(host: String, port: Int, user: String, hostKey: String) {
            self.host = host; self.port = port; self.user = user; self.hostKey = hostKey
        }
        var knownHostsName: String { port == 22 ? host : "[\(host)]:\(port)" }
    }

    /// Tag on the target's authorized_keys line, so it can be removed exactly.
    public static func tag(_ source: UUID) -> String { "deckhand-transfer-" + source.uuidString.prefix(8).lowercased() }

    /// On the source: creates the transfer key once, writes the target's pinned host key, prints `@@pub <key>` and
    /// `@@tools rsync|scp`.
    public static func prepareSourceCommand(target: Target) -> String {
        let hostKey = target.hostKey.split(separator: " ").prefix(2).joined(separator: " ")
        return """
        D=\(dir); mkdir -p "$D" && chmod 700 "$D"
        [ -f "$D/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C deckhand-transfer -f "$D/id_ed25519" >/dev/null || { echo '@@failed no ssh-keygen'; exit 0; }
        printf '%s %s\\n' \(ShellQuote.quote(target.knownHostsName)) \(ShellQuote.quote(hostKey)) > "$D/known_hosts"
        echo "@@pub $(cat "$D/id_ed25519.pub")"
        command -v rsync >/dev/null 2>&1 && echo '@@tools rsync' || echo '@@tools scp'
        """
    }

    /// On the target: accepts the key (no forwarding, no PTY). Also reports whether rsync is there.
    public static func authorizeCommand(publicKey: String, tag: String) -> String {
        let key = publicKey.split(separator: " ").prefix(2).joined(separator: " ")
        let line = "no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty \(key) \(tag)"
        return """
        mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        grep -qF \(ShellQuote.quote(tag)) ~/.ssh/authorized_keys || printf '%s\\n' \(ShellQuote.quote(line)) >> ~/.ssh/authorized_keys
        command -v rsync >/dev/null 2>&1 && echo '@@tools rsync' || echo '@@tools scp'
        echo '@@ok'
        """
    }

    /// On the target: removes the key again (only the line with the tag).
    public static func revokeCommand(tag: String) -> String {
        """
        f=~/.ssh/authorized_keys; [ -f "$f" ] || { echo '@@ok'; exit 0; }
        grep -vF \(ShellQuote.quote(tag)) "$f" > "$f.dh" ; cat "$f.dh" > "$f"; rm -f -- "$f.dh"
        echo '@@ok'
        """
    }

    /// The copy, to run on the source (as a detached job): rsync with resume and progress, or scp.
    /// `source` is a file or folder; it lands inside `destination`.
    public static func copyCommand(source: String, target: Target, destination: String, useRsync: Bool) -> String {
        let ssh = "ssh -i \(dir)/id_ed25519 -p \(target.port) -o UserKnownHostsFile=\(dir)/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15"
        let remote = "\(target.user)@\(target.host.contains(":") ? "[\(target.host)]" : target.host):\(destination.hasSuffix("/") ? destination : destination + "/")"
        let src = ServerTools.shellPath(source)
        if useRsync {
            return "\(ssh) \(ShellQuote.quote(target.user + "@" + target.host)) mkdir -p \(ShellQuote.quote(destination)) 2>&1 "
                + "&& rsync -a --partial --info=progress2 --no-inc-recursive -e \(ShellQuote.quote(ssh)) \(src) \(ShellQuote.quote(remote)) 2>&1 | tr '\\r' '\\n'"
        }
        return "\(ssh) \(ShellQuote.quote(target.user + "@" + target.host)) mkdir -p \(ShellQuote.quote(destination)) 2>&1 "
            + "&& scp -r -P \(target.port) -i \(dir)/id_ed25519 -o UserKnownHostsFile=\(dir)/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes \(src) \(ShellQuote.quote(remote)) 2>&1"
    }

    public struct Progress: Sendable, Hashable {
        public var percent: Int
        public var bytes: Int64
        public var speed: String
    }

    /// The last rsync `--info=progress2` line: `  1,234,567  45%   10.20MB/s    0:00:12 (xfr#3, to-chk=0/5)`.
    public static func progress(_ out: String) -> Progress? {
        for line in out.split(separator: "\n").reversed() {
            let f = line.split(separator: " ")
            guard f.count >= 3, f[1].hasSuffix("%"), let pct = Int(f[1].dropLast()) else { continue }
            return Progress(percent: pct, bytes: Int64(f[0].filter(\.isNumber)) ?? 0, speed: String(f[2]))
        }
        return nil
    }

    /// A readable reason for the usual failures.
    public static func explain(_ out: String) -> String? {
        let o = out.lowercased()
        if o.contains("host key verification failed") || o.contains("remote host identification has changed") {
            return "The target's host key doesn't match the one Deckhand pinned. Nothing was copied."
        }
        if o.contains("could not resolve hostname") || o.contains("name or service not known") {
            return "The source server can't resolve the target's address. Use an address both can reach (e.g. a Tailscale name)."
        }
        if o.contains("connection timed out") || o.contains("connection refused") || o.contains("no route to host") {
            return "The source server can't reach the target's SSH port."
        }
        if o.contains("permission denied") { return "The target refused the transfer key or the destination isn't writable." }
        if o.contains("no space left") { return "The target ran out of disk space." }
        return nil
    }
}
