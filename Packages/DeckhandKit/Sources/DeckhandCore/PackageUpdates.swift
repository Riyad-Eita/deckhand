import Foundation

/// One package with a newer version waiting.
public struct PackageUpdate: Sendable, Hashable, Identifiable {
    public var name: String
    public var current: String?
    public var available: String
    /// Where it comes from, e.g. `jammy-security` or `baseos`.
    public var source: String
    public var isSecurity: Bool
    public var id: String { name }
}

public struct UpdateStatus: Sendable, Hashable {
    /// `apt`, `dnf` or nil when neither is there.
    public var manager: String?
    public var updates: [PackageUpdate]
    public var rebootRequired: Bool
    /// Packages that asked for the restart (Debian/Ubuntu), or the newer kernel.
    public var rebootReasons: [String]
    /// Days since the package lists were refreshed (apt).
    public var listAgeDays: Int?
    public var runningKernel: String

    public var security: [PackageUpdate] { updates.filter(\.isSecurity) }
    public var other: [PackageUpdate] { updates.filter { !$0.isSecurity } }
}

/// Package updates with apt or dnf: what is waiting, install security or all, and whether a restart is due.
public enum PackageUpdates {
    /// Read-only: works without root.
    public static let statusCommand = #"""
    pm=none; command -v apt-get >/dev/null 2>&1 && pm=apt; [ $pm = none ] && command -v dnf >/dev/null 2>&1 && pm=dnf
    echo "@@pm $pm"
    echo "@@kernel $(uname -r)"
    newest=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | grep -v rescue | sort -V | tail -1)
    [ -n "$newest" ] && echo "@@newestkernel $newest"
    if [ $pm = apt ]; then
      stamp=$(stat -c %Y /var/lib/apt/periodic/update-success-stamp /var/lib/apt/lists 2>/dev/null | sort -n | tail -1)
      [ -n "$stamp" ] && echo "@@listage $(( ($(date +%s) - stamp) / 86400 ))"
      [ -f /var/run/reboot-required ] && echo "@@reboot"
      sed 's/^/@@rebootpkg /' /var/run/reboot-required.pkgs 2>/dev/null
      echo "@@list"; apt list --upgradable 2>/dev/null | grep -v '^Listing'
    elif [ $pm = dnf ]; then
      if command -v needs-restarting >/dev/null 2>&1; then needs-restarting -r >/dev/null 2>&1; [ $? = 1 ] && echo "@@reboot"; fi
      echo "@@list"; dnf -q check-update 2>/dev/null
      echo "@@security"; dnf -q updateinfo list --security 2>/dev/null
    fi
    true
    """#

    public static func parse(_ output: String) -> UpdateStatus {
        var pm: String?
        var kernel = "", newest: String?
        var reboot = false
        var reasons: [String] = []
        var age: Int?
        var updates: [PackageUpdate] = []
        var securityNames = Set<String>()
        var section = ""
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@pm ") { let v = String(line.dropFirst(5)); pm = v == "none" ? nil : v; continue }
            if line.hasPrefix("@@kernel ") { kernel = String(line.dropFirst(9)); continue }
            if line.hasPrefix("@@newestkernel ") { newest = String(line.dropFirst(15)); continue }
            if line.hasPrefix("@@listage ") { age = Int(line.dropFirst(10)); continue }
            if line == "@@reboot" { reboot = true; continue }
            if line.hasPrefix("@@rebootpkg ") { reasons.append(String(line.dropFirst(12))); continue }
            if line == "@@list" || line == "@@security" { section = line; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                // dnf: an empty line ends the update list ("Obsoleting Packages" follows).
                if section == "@@list" && pm == "dnf" && !updates.isEmpty { section = "done" }
                continue
            }
            switch (section, pm) {
            case ("@@list", "apt"?):
                if let u = parseApt(trimmed) { updates.append(u) }
            case ("@@list", "dnf"?):
                if let u = parseDnf(trimmed) { updates.append(u) }
            case ("@@security", _):
                // RHSA-2024:1234 Important/Sec. openssl-libs-1:3.0.7-27.el9.x86_64
                let f = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if f.count >= 3 { securityNames.insert(packageName(fromNEVRA: String(f[2]))) }
            default: break
            }
        }
        if !securityNames.isEmpty {
            for i in updates.indices {
                let base = updates[i].name.split(separator: ".").dropLast().joined(separator: ".")
                if securityNames.contains(updates[i].name) || securityNames.contains(base) { updates[i].isSecurity = true }
            }
        }
        // A newer kernel is installed than the one running.
        if let newest, !kernel.isEmpty, newest != kernel,
           newest.compare(kernel, options: .numeric) == .orderedDescending {
            reboot = true
            reasons.append("linux \(newest)")
        }
        updates.sort { a, b in a.isSecurity != b.isSecurity ? a.isSecurity : a.name < b.name }
        return UpdateStatus(manager: pm, updates: updates, rebootRequired: reboot, rebootReasons: Array(Set(reasons)).sorted(),
                            listAgeDays: age, runningKernel: kernel)
    }

    /// `openssl/jammy-updates,jammy-security 3.0.2-0ubuntu1.15 amd64 [upgradable from: 3.0.2-0ubuntu1.14]`
    static func parseApt(_ line: String) -> PackageUpdate? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 3, let slash = f[0].firstIndex(of: "/") else { return nil }
        let name = String(f[0][..<slash])
        let source = String(f[0][f[0].index(after: slash)...])
        var current: String?
        if let r = line.range(of: "[upgradable from: ") {
            current = String(line[r.upperBound...].dropLast(line.hasSuffix("]") ? 1 : 0))
        }
        return PackageUpdate(name: name, current: current, available: String(f[1]), source: source,
                             isSecurity: source.split(separator: ",").contains { $0.hasSuffix("-security") })
    }

    /// `openssl-libs.x86_64   1:3.0.7-27.el9   baseos`
    static func parseDnf(_ line: String) -> PackageUpdate? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count == 3, f[0].contains("."), f[1].first?.isNumber == true else { return nil }
        return PackageUpdate(name: String(f[0]), current: nil, available: String(f[1]), source: String(f[2]), isSecurity: false)
    }

    /// `openssl-libs-1:3.0.7-27.el9.x86_64` → `openssl-libs`: the name ends before the first `-` followed by a digit.
    static func packageName(fromNEVRA s: String) -> String {
        let chars = Array(s)
        for i in chars.indices.dropLast() where chars[i] == "-" && chars[i + 1].isNumber {
            return String(chars[..<i])
        }
        return s
    }

    // MARK: - Root scripts (run through Sudo)

    /// Refreshes the package lists.
    public static func refreshScript(_ pm: String) -> String {
        pm == "dnf"
            ? "echo '@@step refresh'; dnf -q makecache 2>&1 | tail -n 5; echo '@@done'"
            : "echo '@@step refresh'; apt-get update -q 2>&1 | tail -n 5; echo '@@done'"
    }

    /// Installs updates: all, or only `packages` (e.g. the security ones). Keeps changed config files.
    public static func installScript(_ pm: String, packages: [String]? = nil) -> String {
        let names = (packages ?? []).map(ShellQuote.quote).joined(separator: " ")
        if pm == "dnf" {
            let what = packages == nil ? "upgrade" : "upgrade \(names)"
            return "set -o pipefail; echo '@@step install'; dnf -y \(what) 2>&1 | tail -n 60; echo '@@done'"
        }
        let install = packages == nil
            ? "apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade"
            : "apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install --only-upgrade \(names)"
        return """
        set -o pipefail
        export DEBIAN_FRONTEND=noninteractive
        echo '@@step refresh'; apt-get update -q 2>&1 | tail -n 3
        echo '@@step install'; \(install) 2>&1 | tail -n 60
        echo '@@done'
        """
    }

    /// Restarts the server a few seconds later, so the command can report back before the connection drops.
    public static let rebootScript = "echo '@@step reboot'; nohup sh -c 'sleep 3; systemctl reboot || reboot' >/dev/null 2>&1 </dev/null & echo '@@done'"
}
