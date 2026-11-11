import Foundation

/// When an uptime check fails: collect evidence on the server first (so every engine starts with facts), let an
/// agent diagnose it without changing anything, and apply its suggested fix after one tap.
public enum Incident {
    public struct Evidence: Sendable, Hashable, Identifiable {
        public var id: String { title }
        public var title: String
        public var text: String
    }

    /// Heading the agent puts above its fix; the app offers "Apply fix" when it sees it.
    public static let fixHeading = "Suggested fix"
    /// How much of each section goes into the prompt.
    static let sectionLimit = 2_500

    /// Read-only probe: the failing request, load, memory, disk, failed services, recent errors, what changed lately.
    /// Section title for what changed since the check last worked (needs the change history on the server).
    public static let changesTitle = "Changed since last healthy"

    /// `lastHealthy`: when the check last passed; adds what changed on the server since then.
    public static func evidenceCommand(url: String, lastHealthy: Date? = nil) -> String {
        let u = ShellQuote.quote(url)
        let changes = lastHealthy.map { date in
            """
            if [ -f "$HOME/.deckhand/history/snap.sh" ]; then
              S \(ShellQuote.quote(changesTitle))
              sh "$HOME/.deckhand/history/snap.sh"
              (\(ChangeHistory.sinceCommand(date.addingTimeInterval(-15 * 60), limit: 60_000)))
            fi
            """
        } ?? ""
        return """
        S() { printf '\\n@@section %s\\n' "$1"; }
        S "Request"
        curl -sS -o /dev/null -L --max-time 20 -w 'HTTP %{http_code} after %{time_total}s (connect %{time_connect}s, %{num_redirects} redirects) from %{remote_ip}\\n' \(u) 2>&1 | tail -n 3
        S "Load and memory"
        uptime 2>/dev/null; free -m 2>/dev/null || vm_stat 2>/dev/null | head -n 6
        S "Disk"
        df -hP 2>/dev/null | awk 'NR==1 || $5+0 >= 80'
        S "Failed services"
        if command -v systemctl >/dev/null 2>&1; then systemctl --failed --no-legend --plain 2>/dev/null | head -n 15; fi
        S "Recent errors"
        if command -v journalctl >/dev/null 2>&1; then journalctl -p err --since '-1h' --no-pager -q -o short 2>/dev/null | tail -n 25; fi
        for f in /var/log/nginx/error.log /var/log/apache2/error.log /var/log/caddy/caddy.log; do [ -r "$f" ] && { echo "== $f"; tail -n 10 "$f"; }; done
        S "Containers"
        if command -v docker >/dev/null 2>&1; then docker ps -a --format '{{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null | head -n 20; fi
        S "Listening ports"
        (ss -tlnH 2>/dev/null || netstat -tln 2>/dev/null) | awk '{print $4}' | sort -u | head -n 25 | tr '\\n' ' '; echo
        S "Recent changes"
        tail -n 6 /var/log/apt/history.log 2>/dev/null | grep -E '^(Start-Date|Commandline)'
        find /etc /srv /var/www /opt "$HOME" -maxdepth 3 \\( -name .deckhand -o -name .cache -o -name .git -o -name .local -o -name node_modules \\) -prune -o -type f -mmin -180 -print 2>/dev/null | head -n 15
        \(changes)
        true
        """
    }

    public static func parse(_ output: String) -> [Evidence] {
        var out: [Evidence] = []
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("@@section ") {
                out.append(Evidence(title: String(line.dropFirst(10)), text: ""))
            } else if !out.isEmpty {
                out[out.count - 1].text += (out[out.count - 1].text.isEmpty ? "" : "\n") + line
            }
        }
        return out.map { e in
            // The raw diffs of the change history, as readable lines.
            let text = e.title == changesTitle ? ChangeHistory.summary(ChangeHistory.parseDiff(e.text)) : e.text
            return Evidence(title: e.title, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .filter { !$0.text.isEmpty }
    }

    /// The first-turn prompt: evidence included, diagnosis only, fix in a fixed shape the app can pick up.
    public static func prompt(check c: Uptime.Check, evidence: [Evidence]) -> String {
        let last = c.last.map { $0.status == 0 ? "no answer" : "HTTP \($0.status) after \($0.milliseconds) ms" } ?? "unknown"
        let since = c.downSince.map { " since \($0.formatted(.iso8601))" } ?? ""
        let facts = evidence.map { e in
            let t = e.text.count > sectionLimit ? String(e.text.suffix(sectionLimit)) : e.text
            return "### \(e.title)\n```\n\(t)\n```"
        }.joined(separator: "\n\n")
        return """
        The uptime check "\(c.name)" is failing\(since): \(c.url) expects HTTP \(c.expect)\
        \(c.keyword.isEmpty ? "" : " and the text \"\(c.keyword)\""), last result: \(last).

        Evidence collected on this server just now:

        \(facts.isEmpty ? "(none)" : facts)

        Find the cause. Look further where the evidence points (service status and logs, web server config, recent \
        deploys). Don't change anything yet. Answer with a short diagnosis, then a section "## \(fixHeading)" with the \
        exact shell commands in one ```sh block, or say that no fix on this server is needed.
        """
    }

    /// The approved second turn.
    public static let applyPrompt =
        "Apply the \(fixHeading.lowercased()) now. Then repeat the failing check and tell me in one line whether it is up again."

    /// The commands under "## Suggested fix" in an agent reply, if any.
    public static func suggestedFix(in text: String) -> String? {
        guard let heading = text.range(of: #"(?m)^#{1,4}\s*\#(fixHeading)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let rest = text[heading.upperBound...]
        guard let open = rest.range(of: #"```[a-zA-Z]*\n"#, options: .regularExpression),
              let close = rest[open.upperBound...].range(of: "```") else { return nil }
        let body = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

extension Uptime.Check {
    /// When the check last passed.
    public var lastHealthy: Date? { results.last(where: \.ok)?.date }

    /// When the current outage began (first failed result after the last good one).
    public var downSince: Date? {
        guard isUp == false else { return nil }
        let lastGood = results.lastIndex(where: \.ok)
        let firstBad = lastGood.map { $0 + 1 } ?? 0
        return firstBad < results.count ? results[firstBad].date : nil
    }
}
