import Foundation

/// Uptime checks for websites and APIs that run on the server itself (cron, every minute), so they keep checking
/// while the phone is off. Results go to `~/.deckhand/uptime/<id>.log`; going down or coming back up pushes to the
/// ntfy topic.
public enum Uptime {
    static let dir = "$HOME/.deckhand/uptime"
    static let cronTag = "# deckhand-uptime"

    public struct Check: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var url: String
        /// Minutes between checks: 1, 5, 15 …
        public var every: Int
        /// `200`, or a range like `200-399`.
        public var expect: String
        /// Text the response must contain (optional).
        public var keyword: String
        public var results: [Result] = []
        /// Commands that fix this check, run automatically when it fails.
        public var remedy: Remedy?

        public init(id: String = String(UUID().uuidString.prefix(8)).lowercased(), name: String, url: String,
                    every: Int = 5, expect: String = "200-399", keyword: String = "") {
            self.id = id; self.name = name; self.url = url; self.every = every; self.expect = expect; self.keyword = keyword
        }

        public var last: Result? { results.last }
        public var isUp: Bool? { last?.ok }
        /// Share of successful checks among the stored ones (last 24 h at 1 per minute).
        public var uptime: Double? {
            results.isEmpty ? nil : Double(results.filter(\.ok).count) / Double(results.count)
        }
    }

    public struct Result: Sendable, Hashable {
        public var date: Date
        public var status: Int
        public var milliseconds: Int
        public var ok: Bool
    }

    public struct Status: Sendable, Hashable {
        public var cron: Bool
        public var installed: Bool
        public var checks: [Check]
    }

    /// Runs every minute from cron: due checks, results, and a push when a check goes down or comes back.
    /// A check with a remedy (`<id>.fix`, set up after a fix worked once) runs it when the check fails — at most
    /// `<id>.fixmax` times an hour — checks again, and pushes "Fixed automatically" or an urgent "didn't help".
    static let runner = #"""
    #!/bin/sh
    # Deckhand uptime checks — run by cron every minute.
    D="$HOME/.deckhand/uptime"; [ -f "$D/checks.tsv" ] || exit 0
    TOPIC=; SERVER=; [ -f "$D/config" ] && . "$D/config"
    now=$(date +%s); min=$((now / 60)); TAB=$(printf '\t')
    probe() {
      out=$(curl -s -L -o "$D/.body" -w '%{http_code} %{time_total}' --max-time 20 "$url" 2>/dev/null) || true
      code=$(printf '%s' "$out" | awk '{print $1+0}'); ms=$(printf '%s' "$out" | awk '{printf "%d", $2*1000}')
      ok=1
      case "$expect" in
        *-*) [ "$code" -ge "${expect%-*}" ] && [ "$code" -le "${expect#*-}" ] || ok=0 ;;
        *) [ "$code" = "$expect" ] || ok=0 ;;
      esac
      if [ -n "$keyword" ] && ! grep -qF -- "$keyword" "$D/.body" 2>/dev/null; then ok=0; fi
    }
    push() { # message tags [priority]
      [ -n "$TOPIC" ] || return 0
      click=; [ -n "$SERVER" ] && click="deckhand://uptime/$SERVER/$id"
      curl -fsS -m 10 -H "Title: Deckhand uptime" -H "Tags: $2" -H "Priority: ${3:-default}" ${click:+-H "Click: $click"} -d "$1" "$TOPIC" >/dev/null 2>&1
    }
    while IFS="$TAB" read -r id name url every expect keyword; do
      [ -n "$id" ] || continue
      [ $((min % every)) -eq 0 ] || [ "${FORCE:-}" = 1 ] || continue
      probe
      echo "$now $code $ms $ok" >> "$D/$id.log"
      prev=$(cat "$D/$id.state" 2>/dev/null || echo 1)
      remedy=
      if [ "$ok" = 0 ] && [ -f "$D/$id.fix" ]; then
        max=$(cat "$D/$id.fixmax" 2>/dev/null || echo 3)
        runs=$(awk -v s=$((now - 3600)) '$1 >= s' "$D/$id.fixlog" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$runs" -lt "$max" ]; then
          if command -v timeout >/dev/null 2>&1; then timeout 120 sh "$D/$id.fix" > "$D/$id.fixout" 2>&1 < /dev/null; ec=$?
          else sh "$D/$id.fix" > "$D/$id.fixout" 2>&1 < /dev/null; ec=$?; fi
          tail -n 40 "$D/$id.fixout" > "$D/$id.tmp" && mv "$D/$id.tmp" "$D/$id.fixout"
          sleep "${FIXWAIT:-5}"; first=$code; probe
          echo "$now $ec $ok" >> "$D/$id.fixlog"
          tail -n 200 "$D/$id.fixlog" > "$D/$id.tmp" && mv "$D/$id.tmp" "$D/$id.fixlog"
          if [ "$ok" = 1 ]; then remedy=fixed; echo "$(date +%s) $code $ms 1" >> "$D/$id.log"; else remedy=failed; fi
        fi
      fi
      tail -n 1440 "$D/$id.log" > "$D/$id.tmp" && mv "$D/$id.tmp" "$D/$id.log"
      echo "$ok" > "$D/$id.state"
      if [ "$remedy" = fixed ]; then push "Fixed automatically: $name ($first)" wrench
      elif [ "$remedy" = failed ] && [ "$prev" = 1 ]; then push "Down: $name ($code). The automatic fix didn't help." rotating_light urgent
      elif [ "$prev" != "$ok" ]; then
        if [ "$ok" = 0 ]; then push "Down: $name ($code)" rotating_light; else push "Back up: $name" white_check_mark; fi
      fi
    done < "$D/checks.tsv"
    rm -f "$D/.body"
    """#

    public struct Remedy: Sendable, Hashable {
        public var commands: String
        public var maxPerHour: Int
        public var runs: [RemedyRun] = []
        public var lastOutput = ""
        public init(commands: String, maxPerHour: Int = 3) { self.commands = commands; self.maxPerHour = maxPerHour }
        public var runsToday: [RemedyRun] { runs.filter { Calendar.current.isDateInToday($0.date) } }
    }

    public struct RemedyRun: Sendable, Hashable {
        public var date: Date
        public var exitCode: Int
        public var fixed: Bool
    }

    /// Stores the commands that fix a check (run by the runner when the check fails).
    public static func setRemedyCommand(checkID: String, remedy: Remedy) -> String {
        let id = checkID.filter { $0.isLetter || $0.isNumber }
        // Cron has no terminal: sudo must fail right away instead of waiting for a password.
        let cmds = remedy.commands.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"(^|[;&|(\s])sudo\s+(?!-n\b)"#, with: "$1sudo -n ", options: .regularExpression)
        let body = "#!/bin/sh\n# Deckhand automatic fix\n" + cmds + "\n"
        let b64 = Data(body.utf8).base64EncodedString()
        return """
        D=\(dir); mkdir -p "$D" && printf '%s' '\(b64)' | base64 -d > "$D/\(id).fix" && chmod 700 "$D/\(id).fix" \
        && echo \(max(1, min(remedy.maxPerHour, 20))) > "$D/\(id).fixmax" && echo '@@ok'
        """
    }

    public static func removeRemedyCommand(checkID: String) -> String {
        let id = checkID.filter { $0.isLetter || $0.isNumber }
        return "D=\(dir); rm -f \"$D/\(id).fix\" \"$D/\(id).fixmax\" \"$D/\(id).fixlog\" \"$D/\(id).fixout\"; echo '@@ok'"
    }

    /// Installs the runner and the cron line (idempotent) and stores the ntfy topic (empty: no pushes). `server`
    /// (the app's id for this server) makes a tapped push open the incident in the app.
    public static func installCommand(topic: String, server: UUID? = nil) -> String {
        let t = topic.contains("'") ? "" : topic
        return """
        mkdir -p \(dir) && chmod 700 \(dir)
        printf '%s\\n' \(ShellQuote.quote(runner)) > \(dir)/run.sh && chmod 700 \(dir)/run.sh
        printf 'TOPIC=%s\\nSERVER=%s\\n' \(ShellQuote.quote(ShellQuote.quote(t))) '\(server?.uuidString ?? "")' > \(dir)/config
        command -v crontab >/dev/null 2>&1 || { echo '@@nocron'; exit 0; }
        { crontab -l 2>/dev/null | grep -v 'deckhand/uptime/run.sh'; echo "* * * * * $HOME/.deckhand/uptime/run.sh >/dev/null 2>&1 \(cronTag)"; } | crontab -
        echo '@@ok'
        """
    }

    static func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }

    public static func isValid(_ c: Check) -> Bool {
        guard let u = URL(string: c.url), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil else { return false }
        return c.expect.range(of: #"^\d{3}(-\d{3})?$"#, options: .regularExpression) != nil && c.every >= 1 && c.every <= 1440
            && !c.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Adds a check (or replaces one with the same id) and runs it once right away.
    public static func addCommand(_ c: Check) -> String {
        let line = [c.id, clean(c.name), clean(c.url), String(c.every), c.expect, clean(c.keyword)].joined(separator: "\t")
        return """
        D=\(dir); mkdir -p "$D"; touch "$D/checks.tsv"
        grep -v '^\(c.id)\t' "$D/checks.tsv" > "$D/checks.tmp" 2>/dev/null; mv "$D/checks.tmp" "$D/checks.tsv"
        printf '%s\\n' \(ShellQuote.quote(line)) >> "$D/checks.tsv"
        grep '^\(c.id)\t' "$D/checks.tsv" > "$D/one.tsv"; mv "$D/checks.tsv" "$D/all.tsv"; mv "$D/one.tsv" "$D/checks.tsv"
        FORCE=1 sh "$D/run.sh"; mv "$D/all.tsv" "$D/checks.tsv"
        echo '@@ok'
        """
    }

    public static func removeCommand(id: String) -> String {
        let safe = id.filter { $0.isLetter || $0.isNumber }
        return """
        D=\(dir); grep -v '^\(safe)\t' "$D/checks.tsv" > "$D/checks.tmp" 2>/dev/null; mv "$D/checks.tmp" "$D/checks.tsv"
        rm -f "$D/\(safe).log" "$D/\(safe).state" "$D/\(safe).fix" "$D/\(safe).fixmax" "$D/\(safe).fixlog" "$D/\(safe).fixout"; echo '@@ok'
        """
    }

    /// Removes everything, including the cron line.
    public static let uninstallCommand = """
    crontab -l 2>/dev/null | grep -v 'deckhand/uptime/run.sh' | crontab - 2>/dev/null; rm -rf \(dir); echo '@@ok'
    """

    public static let statusCommand = """
    D=\(dir)
    if command -v crontab >/dev/null 2>&1; then echo '@@cron yes'; else echo '@@cron no'; fi
    crontab -l 2>/dev/null | grep -q 'deckhand/uptime/run.sh' && echo '@@installed'
    [ -f "$D/checks.tsv" ] || exit 0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      echo "@@check $line"; id=$(printf '%s' "$line" | cut -f1)
      [ -f "$D/$id.log" ] && sed 's/^/@@r /' "$D/$id.log"
      if [ -f "$D/$id.fix" ]; then
        echo "@@fix $(cat "$D/$id.fixmax" 2>/dev/null || echo 3) $(tail -n +3 "$D/$id.fix" | base64 | tr -d '\n')"
        [ -f "$D/$id.fixlog" ] && sed 's/^/@@fr /' "$D/$id.fixlog"
        [ -f "$D/$id.fixout" ] && echo "@@fo $(base64 < "$D/$id.fixout" | tr -d '\n')"
      fi
    done < "$D/checks.tsv"
    true
    """

    public static func parse(_ output: String) -> Status {
        var s = Status(cron: false, installed: false, checks: [])
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == "@@cron yes" { s.cron = true }
            else if line == "@@installed" { s.installed = true }
            else if line.hasPrefix("@@check ") {
                let f = String(line.dropFirst(8)).components(separatedBy: "\t")
                guard f.count >= 5 else { continue }
                s.checks.append(Check(id: f[0], name: f[1], url: f[2], every: Int(f[3]) ?? 5, expect: f[4], keyword: f.count > 5 ? f[5] : ""))
            } else if line.hasPrefix("@@fix "), !s.checks.isEmpty {
                let f = line.dropFirst(6).split(separator: " ", maxSplits: 1).map(String.init)
                let cmds = f.count > 1 ? Data(base64Encoded: f[1]).flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
                s.checks[s.checks.count - 1].remedy = Remedy(commands: cmds.trimmingCharacters(in: .whitespacesAndNewlines), maxPerHour: Int(f.first ?? "") ?? 3)
            } else if line.hasPrefix("@@fr "), !s.checks.isEmpty, s.checks[s.checks.count - 1].remedy != nil {
                let p = line.dropFirst(5).split(separator: " ").compactMap { Int($0) }
                guard p.count == 3 else { continue }
                s.checks[s.checks.count - 1].remedy?.runs.append(RemedyRun(date: Date(timeIntervalSince1970: Double(p[0])), exitCode: p[1], fixed: p[2] == 1))
            } else if line.hasPrefix("@@fo "), !s.checks.isEmpty {
                s.checks[s.checks.count - 1].remedy?.lastOutput = Data(base64Encoded: String(line.dropFirst(5))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            } else if line.hasPrefix("@@r "), !s.checks.isEmpty {
                let p = line.dropFirst(4).split(separator: " ").compactMap { Int($0) }
                guard p.count == 4 else { continue }
                s.checks[s.checks.count - 1].results.append(
                    Result(date: Date(timeIntervalSince1970: Double(p[0])), status: p[1], milliseconds: p[2], ok: p[3] == 1))
            }
        }
        return s
    }
}
