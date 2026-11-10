import CryptoKit
import Foundation

/// The keys allowed to log in as this user (`~/.ssh/authorized_keys`): list them, remove some.
public enum AuthorizedKeys {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var type: String
        /// The base64 key blob — identifies the key.
        public var blob: String
        public var comment: String
        /// `SHA256:…` like `ssh-keygen -l`.
        public var fingerprint: String
        public var id: String { blob }
    }

    public static let listCommand = "cat ~/.ssh/authorized_keys 2>/dev/null; true"

    static let keyTypes: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com", "ssh-dss",
    ]

    public static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Lines may start with options (from="…",command="…"); the key type comes after them.
            guard let i = fields.firstIndex(where: { keyTypes.contains($0) }), i + 1 < fields.count else { return nil }
            let blob = fields[i + 1]
            return Entry(type: fields[i], blob: blob, comment: fields[(i + 2)...].joined(separator: " "), fingerprint: fingerprint(blob: blob))
        }
    }

    public static func fingerprint(blob: String) -> String {
        guard let data = Data(base64Encoded: blob) else { return "?" }
        let b64 = Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + b64
    }

    /// The blob of an OpenSSH public key line (`ssh-ed25519 AAAA… comment`).
    public static func blob(ofPublicKey line: String) -> String? {
        let f = line.split(separator: " ").map(String.init)
        return f.count >= 2 && keyTypes.contains(f[0]) ? f[1] : nil
    }

    /// Removes every line whose key is one of `blobs`. Keeps a backup next to the file. Prints how many are left.
    public static func removeCommand(blobs: [String]) -> String? {
        let valid = blobs.filter { $0.range(of: #"^[A-Za-z0-9+/=]{20,}$"#, options: .regularExpression) != nil }
        guard !valid.isEmpty else { return nil }
        return """
        F=~/.ssh/authorized_keys; [ -f "$F" ] || { echo '@@none'; exit 0; }
        cp -p "$F" "$F.deckhand-bak"
        T=$(mktemp) && awk -v keys=\(ShellQuote.quote(valid.joined(separator: " "))) 'BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) drop[k[i]] = 1 } { for (i = 1; i <= NF; i++) if ($i in drop) next; print }' "$F" > "$T" && cat "$T" > "$F"; rm -f "$T"
        echo "@@left $(grep -cvE '^[[:space:]]*(#|$)' "$F")"
        """
    }
}
