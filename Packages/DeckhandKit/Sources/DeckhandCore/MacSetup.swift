import Foundation

/// "Use this Mac from your iPhone": what the Mac shows so the iPhone can add it as a server — a deckhand://add link
/// (as a QR code) with the Mac's address and user name. No password or key travels; the iPhone signs in once with
/// the Mac password and then switches to its own key.
public enum MacSetup {
    /// "Riads-MacBook-Pro.local" → "Riads MacBook Pro".
    public static func displayName(hostName: String) -> String {
        var name = hostName
        if let dot = name.firstIndex(of: ".") { name = String(name[..<dot]) }
        name = name.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Mac" : name
    }

    /// The address the iPhone should use: an override (a Tailscale name or IP) if given, else the Bonjour name
    /// ("name.local"), which works on the same network.
    public static func address(hostName: String, override: String = "") -> String {
        let o = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { return o }
        let h = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return "" }
        return h.contains(".") ? h : h + ".local"
    }

    /// The link the QR code carries.
    public static func link(hostName: String, user: String, override: String = "") -> String? {
        let host = address(hostName: hostName, override: override)
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !user.isEmpty else { return nil }
        return HostLink.link(for: .init(name: displayName(hostName: hostName), host: host, user: user))
    }
}
