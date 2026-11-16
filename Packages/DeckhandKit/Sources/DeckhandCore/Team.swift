import Foundation

/// Letting other people onto a server: each teammate gets their own Linux account with the rights the owner picks,
/// joined by scanning a QR code (the same one-time key as first-time pairing). The owner's own password or key is
/// never shared. Who was invited is kept in the owner's `~/.deckhand/team/<user>.json`.
public enum Team {
    public static let directory = "~/.deckhand/team"
    /// Starts the comment of every account Deckhand makes; only such accounts can be removed from the app.
    static let marker = "Deckhand - "

    public enum Role: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Own account, no sudo, no extra groups or folders: can look around, read logs it may read, use its home.
        case readOnly
        /// Own account plus chosen groups (e.g. `docker`) and folders it may write to. No sudo.
        case developer
        /// Own account with sudo.
        case admin

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .readOnly: String(localized: "Read only")
            case .developer: String(localized: "Developer")
            case .admin: String(localized: "Admin")
            }
        }
        public var explanation: String {
            switch self {
            case .readOnly: String(localized: "Their own account without sudo. They can look around and read, but not change the system or your files.")
            case .developer: String(localized: "Like read only, plus the groups and folders you pick below — for example docker and your app's folder. No sudo.")
            case .admin: String(localized: "Their own account with sudo: they can change anything on this server.")
            }
        }
    }

    public struct Member: Codable, Sendable, Hashable, Identifiable {
        /// The Linux user name.
        public var user: String
        /// Who it is, as the owner typed it.
        public var person: String
        public var role: Role
        public var groups: [String]
        public var folders: [String]
        /// The account stops working at the end of this day (server time).
        public var expires: Date?
        public var invited: Date
        /// Until when the QR code works.
        public var inviteUntil: Date
        public var id: String { user }

        public init(user: String, person: String, role: Role, groups: [String] = [], folders: [String] = [], expires: Date? = nil,
                    invited: Date = Date(), inviteUntil: Date) {
            self.user = user; self.person = person; self.role = role
            self.groups = role == .developer ? groups : []
            self.folders = role == .developer ? folders : []
            self.expires = expires; self.invited = invited; self.inviteUntil = inviteUntil
        }
    }

    /// A member as found on the server.
    public struct Entry: Sendable, Hashable, Identifiable {
        public var member: Member
        /// The account exists.
        public var exists: Bool
        /// When they last signed in (joining counts), if the server keeps that.
        public var lastLogin: Date?
        /// The account still waits for its one-time key.
        public var pending: Bool
        public var id: String { member.user }

        public init(member: Member, exists: Bool, lastLogin: Date?, pending: Bool) {
            self.member = member; self.exists = exists; self.lastLogin = lastLogin; self.pending = pending
        }

        public func state(now: Date = Date()) -> State {
            if !exists { return .removed }
            if let e = member.expires, now >= e { return .expired }
            if pending { return now >= member.inviteUntil ? .inviteExpired : .invited }
            return .active
        }
    }

    public enum State: Sendable, Hashable { case invited, inviteExpired, active, expired, removed }

    /// A Linux user name: lowercase letter or underscore first, then lowercase letters, digits, `_` or `-`.
    public static func isValidUser(_ s: String) -> Bool {
        s.count <= 32 && s.range(of: #"^[a-z_][a-z0-9_-]*$"#, options: .regularExpression) != nil
            && !["root", "daemon", "bin", "sys", "sync", "nobody", "admin", "sudo", "www-data"].contains(s)
    }

    /// A user name made from a name: "Anna Müller" → "anna".
    public static func suggestedUser(for person: String) -> String {
        let first = person.split(separator: " ").first.map(String.init) ?? person
        let ascii = first.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
            .lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        let name = ascii.first?.isLetter == true ? ascii : "u" + ascii
        return String(name.prefix(32))
    }

    /// A group name or an absolute folder path that is safe to put into a script.
    static func isGroup(_ s: String) -> Bool { s.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil }
    static func isFolder(_ s: String) -> Bool {
        s.hasPrefix("/") && s != "/" && !s.contains("..") && s.range(of: #"^[A-Za-z0-9._/@+-]+$"#, options: .regularExpression) != nil
    }

    /// The forced command a one-time key runs — the same text `scripts/pair.sh` writes.
    public static let acceptScript = #"""
#!/bin/sh
# Deckhand pairing: the only thing a one-time pairing key may do. Adds the public key the app sends
# (in SSH_ORIGINAL_COMMAND) to authorized_keys once, then removes the pairing key. Managed by Deckhand.
id="$1"; D="$HOME/.deckhand/pair"; AK="$HOME/.ssh/authorized_keys"
case "$id" in *[!0-9a-f]*|"") echo "@@bad"; exit 1 ;; esac
drop() {
  grep -v " deckhand-pair-$id\$" "$AK" > "$AK.dh" 2>/dev/null
  cat "$AK.dh" > "$AK"; rm -f "$AK.dh" "$D/$id" "$D/$id.pub" "$D/$id.until"
}
until=$(cat "$D/$id.until" 2>/dev/null || echo 0)
if [ "$(date +%s)" -gt "$until" ]; then drop; echo "@@expired"; exit 1; fi
key=${SSH_ORIGINAL_COMMAND:-}
if ! printf '%s\n' "$key" | grep -Eq '^(ssh-ed25519|ecdsa-sha2-nistp256) [A-Za-z0-9+/]{40,255}={0,2} [A-Za-z0-9 ._@()-]{1,60}$'; then
  echo "@@badkey"; exit 1
fi
grep -qxF -- "$key" "$AK" || printf '%s\n' "$key" >> "$AK"
drop
echo "@@paired"
"""#

    /// Installs a one-time key for the account whose home is `$H` (owner `$U`): accept script, deadline and the
    /// locked-down authorized_keys line. Used by the invite (as root) and by "share my own access" (as the owner).
    static func oneTimeKeySteps(publicKey: String, id: String, until: Date) -> String {
        """
        P="$H/.deckhand/pair"
        mkdir -p "$H/.ssh" "$P"
        printf '%s\\n' \(ShellQuote.quote(acceptScript)) > "$P/accept.sh"
        echo \(Int(until.timeIntervalSince1970)) > "$P/\(id).until"
        touch "$H/.ssh/authorized_keys"
        OPTS="restrict,command=\\"/bin/sh $P/accept.sh \(id)\\""
        v=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\\([0-9]*\\)\\.\\([0-9]*\\).*/\\1 \\2/p')
        if [ -n "$v" ] && [ "$(echo "$v" | awk '{print ($1 > 8 || ($1 == 8 && $2 >= 2)) ? 1 : 0}')" = 1 ]; then
          E=$(date -d @\(Int(until.timeIntervalSince1970)) +%Y%m%d%H%M 2>/dev/null || date -r \(Int(until.timeIntervalSince1970)) +%Y%m%d%H%M)
          OPTS="$OPTS,expiry-time=\\"$E\\""
        fi
        printf '%s %s\\n' "$OPTS" \(ShellQuote.quote(publicKey + " deckhand-pair-" + id)) >> "$H/.ssh/authorized_keys"
        chmod 700 "$H/.ssh" "$H/.deckhand" "$P" "$P/accept.sh"; chmod 600 "$H/.ssh/authorized_keys"
        """
    }

    /// `publicKey` is the one-time key's `ssh-ed25519 AAAA…` (no comment); `id` 12 hex characters.
    static func validOneTime(_ publicKey: String, _ id: String) -> Bool {
        publicKey.range(of: #"^ssh-ed25519 [A-Za-z0-9+/]{40,100}={0,2}$"#, options: .regularExpression) != nil
            && id.range(of: #"^[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    /// Run as root: creates the account with its role and puts the one-time key in place. Prints `@@invited`, or
    /// `@@exists` when the user name is taken.
    public static func inviteScript(_ m: Member, oneTimePublicKey: String, id: String) -> String {
        guard isValidUser(m.user), validOneTime(oneTimePublicKey, id) else { return "echo '@@failed bad input'; exit 2" }
        let groups = m.groups.filter(isGroup)
        let folders = m.folders.filter(isFolder)
        let expiry = m.expires.map { "-e " + Self.day($0) } ?? ""
        let comment = ShellQuote.quote(marker + String(m.person.filter { $0 != ":" && $0 != "," && !$0.isNewline }.prefix(60)))
        return """
        U=\(m.user)
        echo '@@step Create the account'
        if id "$U" >/dev/null 2>&1; then echo '@@exists'; exit 3; fi
        useradd -m -s /bin/bash -c \(comment) \(expiry) "$U" || { echo '@@failed useradd'; exit 5; }
        H=$(getent passwd "$U" | cut -d: -f6)
        [ -n "$H" ] && [ -d "$H" ] || { echo '@@failed home'; exit 5; }
        \(groups.isEmpty ? "" : "echo '@@step Groups'")
        \(groups.map { "getent group \($0) >/dev/null && usermod -aG \($0) \"$U\"" }.joined(separator: "\n"))
        \(m.role == .admin ? sudoSteps : "")
        \(folders.isEmpty ? "" : folderSteps(folders, add: true))
        echo '@@step One-time key'
        \(oneTimeKeySteps(publicKey: oneTimePublicKey, id: id, until: m.inviteUntil))
        chown -R "$U:$(id -gn "$U")" "$H/.ssh" "$H/.deckhand" || { echo '@@failed key'; exit 6; }
        echo '@@invited'
        """
    }

    static let sudoSteps = """
        echo '@@step Sudo'
        F="/etc/sudoers.d/deckhand-$U"
        printf '%s ALL=(ALL) NOPASSWD:ALL\\n' "$U" > "$F"; chmod 440 "$F"
        visudo -cf "$F" >/dev/null || { rm -f "$F"; echo '@@failed sudoers'; exit 4; }
        """

    static func folderSteps(_ folders: [String], add: Bool) -> String {
        let body = folders.map { f in
            add ? "[ -d \(ShellQuote.quote(f)) ] && setfacl -R -m u:\"$U\":rwX -m d:u:\"$U\":rwX \(ShellQuote.quote(f))"
                : "[ -d \(ShellQuote.quote(f)) ] && setfacl -R -x u:\"$U\" -x d:u:\"$U\" \(ShellQuote.quote(f)) 2>/dev/null"
        }.joined(separator: "\n")
        return """
        echo '@@step Folders'
        if command -v setfacl >/dev/null 2>&1; then
        \(body)
        true
        else echo '@@noacl'; fi
        """
    }

    /// Run as root: a new role (sudo on or off, the groups and folders replaced).
    public static func changeScript(from old: Member, to new: Member) -> String {
        guard isValidUser(new.user), old.user == new.user else { return "echo '@@failed bad input'; exit 2" }
        let groups = new.groups.filter(isGroup)
        let removedFolders = old.folders.filter { !new.folders.contains($0) }.filter(isFolder)
        let addedFolders = new.folders.filter(isFolder)
        return """
        U=\(new.user)
        id "$U" >/dev/null 2>&1 || { echo '@@missing'; exit 3; }
        echo '@@step Groups'
        usermod -G \(ShellQuote.quote(groups.joined(separator: ","))) "$U" 2>/dev/null || usermod -G '' "$U"
        \(new.role == .admin ? sudoSteps : "rm -f \"/etc/sudoers.d/deckhand-$U\"")
        \(removedFolders.isEmpty ? "" : folderSteps(removedFolders, add: false))
        \(addedFolders.isEmpty ? "" : folderSteps(addedFolders, add: true))
        \(new.expires.map { "usermod -e \(day($0)) \"$U\"" } ?? "usermod -e '' \"$U\"")
        echo '@@changed'
        """
    }

    /// Run as root: ends their sessions, removes the account and its home, the sudo rule and folder rights.
    public static func removeScript(_ m: Member) -> String {
        guard isValidUser(m.user) else { return "echo '@@failed bad input'; exit 2" }
        let folders = m.folders.filter(isFolder)
        return """
        U=\(m.user)
        if id "$U" >/dev/null 2>&1; then
          case "$(getent passwd "$U" | cut -d: -f5)" in \(ShellQuote.quote(marker))*) ;; *) echo '@@notours'; exit 3 ;; esac
          pkill -KILL -u "$U" 2>/dev/null
          \(folders.isEmpty ? "" : folderSteps(folders, add: false))
          userdel -r "$U" 2>/dev/null || userdel "$U"
        fi
        rm -f "/etc/sudoers.d/deckhand-$U"
        echo '@@removed'
        """
    }

    /// Run as root: a fresh one-time key for an existing member (the first code expired or got lost).
    public static func reinviteScript(user: String, oneTimePublicKey: String, id: String, until: Date) -> String {
        guard isValidUser(user), validOneTime(oneTimePublicKey, id) else { return "echo '@@failed bad input'; exit 2" }
        return """
        U=\(user)
        id "$U" >/dev/null 2>&1 || { echo '@@missing'; exit 3; }
        H=$(getent passwd "$U" | cut -d: -f6)
        grep -v ' deckhand-pair-[0-9a-f]*$' "$H/.ssh/authorized_keys" > "$H/.ssh/authorized_keys.dh" 2>/dev/null
        cat "$H/.ssh/authorized_keys.dh" > "$H/.ssh/authorized_keys" 2>/dev/null; rm -f "$H/.ssh/authorized_keys.dh"
        \(oneTimeKeySteps(publicKey: oneTimePublicKey, id: id, until: until))
        chown -R "$U:$(id -gn "$U")" "$H/.ssh" "$H/.deckhand" || { echo '@@failed key'; exit 6; }
        echo '@@invited'
        """
    }

    /// Run as the owner (no root): one-time key into the owner's own account — "share my own access".
    public static func shareOwnAccessCommand(oneTimePublicKey: String, id: String, until: Date) -> String {
        guard validOneTime(oneTimePublicKey, id) else { return "echo '@@failed bad input'" }
        return "H=\"$HOME\"\n" + oneTimeKeySteps(publicKey: oneTimePublicKey, id: id, until: until) + "\necho '@@invited'"
    }

    /// Stores a member in the owner's list.
    public static func saveCommand(_ m: Member) -> String {
        guard isValidUser(m.user) else { return "echo '@@failed bad input'" }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .secondsSince1970
        let json = String(decoding: (try? enc.encode(m)) ?? Data(), as: UTF8.self)
        return "mkdir -p \(directory) && chmod 700 \(directory) && printf '%s\\n' \(ShellQuote.quote(json)) > \(directory)/\(m.user).json && echo '@@ok'"
    }

    public static func forgetCommand(user: String) -> String {
        guard isValidUser(user) else { return "echo '@@failed bad input'" }
        return "rm -f \(directory)/\(user).json; echo '@@ok'"
    }

    /// The owner's list of invited people: one `@@member <json>` line each (no root needed).
    public static let recordsCommand = #"""
    cd ~/.deckhand/team 2>/dev/null || exit 0
    for f in *.json; do [ -f "$f" ] && echo "@@member $(head -n 1 "$f")"; done; true
    """#

    /// Run as root: for each user `@@status <user> <exists 0|1> <pending 0|1> <last login epoch, 0 = unknown>`.
    /// Pending means the one-time key is still in their authorized_keys (joining removes it).
    public static func statusScript(users: [String]) -> String {
        let list = users.filter(isValidUser).joined(separator: " ")
        return """
        for u in \(list); do
          if ! id "$u" >/dev/null 2>&1; then echo "@@status $u 0 0 0"; continue; fi
          h=$(getent passwd "$u" | cut -d: -f6)
          p=0; grep -q ' deckhand-pair-[0-9a-f]*$' "$h/.ssh/authorized_keys" 2>/dev/null && p=1
          t=0
          l=$(lastlog -u "$u" 2>/dev/null | tail -n 1)
          case "$l" in *"Never logged in"*|"") ;; *) t2=$(date -d "$(printf '%s' "$l" | awk '{print $(NF-4), $(NF-3), $(NF-2), $(NF-1), $NF}')" +%s 2>/dev/null) && t=$t2 ;; esac
          echo "@@status $u 1 $p $t"
        done
        true
        """
    }

    public static func parseRecords(_ output: String) -> [Member] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return output.split(separator: "\n").compactMap { line in
            line.hasPrefix("@@member ") ? try? dec.decode(Member.self, from: Data(line.dropFirst(9).utf8)) : nil
        }
        .sorted { $0.invited > $1.invited }
    }

    /// The records joined with what root saw on the server.
    public static func entries(_ members: [Member], status output: String) -> [Entry] {
        var seen: [String: (Bool, Bool, Date?)] = [:]
        for line in output.split(separator: "\n") where line.hasPrefix("@@status ") {
            let p = line.split(separator: " ").map(String.init)
            guard p.count == 5 else { continue }
            let t = Double(p[4]) ?? 0
            seen[p[1]] = (p[2] == "1", p[3] == "1", t > 0 ? Date(timeIntervalSince1970: t) : nil)
        }
        return members.map { m in
            let s = seen[m.user]
            return Entry(member: m, exists: s?.0 ?? true, lastLogin: s?.2, pending: s?.1 ?? false)
        }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

extension Pairing {
    /// The link for a code — the inverse of `parse`.
    public static func link(_ c: Code) -> String {
        var parts = URLComponents()
        parts.scheme = "deckhand"
        parts.host = "pair"
        let seed = c.seed.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        parts.queryItems = [
            URLQueryItem(name: "h", value: c.host), URLQueryItem(name: "p", value: String(c.port)), URLQueryItem(name: "u", value: c.user),
            URLQueryItem(name: "n", value: c.name), URLQueryItem(name: "k", value: seed),
            URLQueryItem(name: "f", value: c.fingerprints.map { $0.replacingOccurrences(of: "SHA256:", with: "") }.joined(separator: ",")),
            URLQueryItem(name: "e", value: String(Int(c.expires.timeIntervalSince1970))),
        ]
        return (parts.string ?? "deckhand://pair").replacingOccurrences(of: "+", with: "%2B")
    }
}
