import Foundation

/// A recurring agent task: "every Monday at 6:00, install security updates and restart what needs it".
public struct AgentSchedule: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var prompt: String
    public var cli: ServerCLI
    public var directory: String
    public var access: CLIAccess
    /// Five-field cron expression, built with `CronEditor.Schedule`.
    public var cron: String
    public var paused: Bool
    public var model: String?
    public var effort: String?
    /// The house rules' spending cap at the time the schedule was saved (Claude Code only).
    public var maxBudgetUSD: Double?
    /// Push through the user's ntfy topic when a run ends.
    public var notifyTopic: String?
    public var created: Date

    public init(
        id: String = AgentSchedules.newID(), name: String, prompt: String, cli: ServerCLI, directory: String = "~",
        access: CLIAccess = .readOnly, cron: String, paused: Bool = false, options: CLIOptions = .init(),
        notifyTopic: String? = nil, created: Date = Date()
    ) {
        self.id = id; self.name = name; self.prompt = prompt; self.cli = cli; self.directory = directory
        self.access = access; self.cron = cron; self.paused = paused
        model = options.model; effort = options.effort; maxBudgetUSD = options.maxBudgetUSD
        self.notifyTopic = notifyTopic.flatMap { $0.isEmpty ? nil : $0 }
        self.created = created
    }

    public var options: CLIOptions { CLIOptions(model: model, effort: effort, maxBudgetUSD: maxBudgetUSD) }

    /// "Mon at 06:00", "Every day at 03:00", …
    public var when: String { CronEditor.Schedule.from(cron).description }
}

/// Scheduled agent tasks live on the server, so they run while the phone is off:
/// `~/.deckhand/schedules/<id>.json` (the definition), `<id>.sh` (the runner) and one crontab line ending in
/// `# deckhand-schedule <id>` (commented out while paused). Every run is an ordinary detached run
/// (`~/.deckhand/runs/s-<id>-<time>`) with the same CLI command, usage-limit handling and house rules hook as a task
/// started from the phone, so it shows up under Background tasks. A run is skipped while the previous one still runs.
public enum AgentSchedules {
    public static let directory = "~/.deckhand/schedules"

    /// Eight lowercase letters and digits.
    public static func newID() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    public static func isValidID(_ id: String) -> Bool {
        id.count == 8 && id.unicodeScalars.allSatisfy { CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    static func tag(_ id: String) -> String { "# deckhand-schedule \(id)" }

    /// The crontab line; output goes to the run's files, so cron mails nothing.
    public static func cronLine(_ s: AgentSchedule) -> String {
        (s.paused ? "#" : "") + "\(s.cron) bash \(directory)/\(s.id).sh >/dev/null 2>&1 \(tag(s.id))"
    }

    /// The runner cron starts. It picks a new run id, skips while the last run is still going and starts the CLI turn
    /// detached, exactly like the app does.
    public static func runnerScript(_ s: AgentSchedule) -> String {
        let run = DetachedRun(id: "${RID}")
        let cli = LimitAwareRun.command(
            s.cli, prompt: s.prompt, workingDirectory: s.directory, sessionID: nil, access: s.access, options: s.options, run: run)
        let notify = s.notifyTopic.map {
            DetachedRun.Notify(topicURL: $0, doneMessage: "Done: \(s.name)", failedMessage: "Didn't finish: \(s.name)")
        }
        let meta: JSONValue = .object([
            "title": .string(s.name), "engine": .string(s.cli.displayName), "directory": .string(s.directory), "schedule": .string(s.id),
        ])
        // `started` is filled in when the run starts.
        let metaJSON = String(meta.jsonString().dropLast()) + ",\"started\":__NOW__}"
        return """
        #!/bin/bash
        # Deckhand scheduled task \(s.id). Managed by the Deckhand app; change it there.
        export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
        D=\(directory); I=\(s.id)
        mkdir -p ~/.deckhand/runs; chmod 700 ~/.deckhand ~/.deckhand/runs
        last=$(cat "$D/$I.last" 2>/dev/null)
        if [ -n "$last" ] && [ ! -f ~/.deckhand/runs/"$last".exit ] && kill -0 "$(cat ~/.deckhand/runs/"$last".pid 2>/dev/null)" 2>/dev/null; then
          echo "$(date +%s) skipped $last" >> "$D/$I.log"; exit 0
        fi
        RID="s-$I-$(date +%Y%m%d-%H%M%S)"; export RID
        echo "$RID" > "$D/$I.last"
        { tail -n 199 "$D/$I.log" 2>/dev/null; echo "$(date +%s) started $RID"; } > "$D/$I.log.tmp" && mv "$D/$I.log.tmp" "$D/$I.log"
        M=\(ShellQuote.quote(metaJSON))
        printf '%s\\n' "${M/__NOW__/$(date +%s)}" > ~/.deckhand/runs/"$RID".meta
        \(run.startCommand(cli, notify: notify))
        """
    }

    /// Writes the definition and the runner and puts the crontab line in place (replacing an older one).
    public static func saveCommand(_ s: AgentSchedule) -> String {
        guard isValidID(s.id) else { return "echo '@@failed bad id'" }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .secondsSince1970
        let json = String(decoding: (try? enc.encode(s)) ?? Data(), as: UTF8.self)
        return """
        mkdir -p \(directory) && chmod 700 ~/.deckhand \(directory)
        printf '%s\\n' \(ShellQuote.quote(json)) > \(directory)/\(s.id).json
        printf '%s\\n' \(ShellQuote.quote(runnerScript(s))) > \(directory)/\(s.id).sh && chmod 700 \(directory)/\(s.id).sh
        T=$(crontab -l 2>/dev/null | grep -v -- ' \(tag(s.id))$')
        { [ -n "$T" ] && printf '%s\\n' "$T"; printf '%s\\n' \(ShellQuote.quote(cronLine(s))); } | crontab - && echo '@@ok'
        """
    }

    /// Removes the crontab line and the schedule's files. Its earlier runs stay under Background tasks.
    public static func deleteCommand(id: String) -> String {
        guard isValidID(id) else { return "echo '@@failed bad id'" }
        return """
        T=$(crontab -l 2>/dev/null | grep -v -- ' \(tag(id))$')
        if [ -n "$T" ]; then printf '%s\\n' "$T" | crontab -; else crontab -r 2>/dev/null; fi
        rm -f \(directory)/\(id).json \(directory)/\(id).sh \(directory)/\(id).last \(directory)/\(id).log \(directory)/\(id).log.tmp
        echo '@@ok'
        """
    }

    /// Starts a run now, outside the schedule. Prints `@@run <run id>` (or `@@skipped` while one is going).
    public static func runNowCommand(id: String) -> String {
        guard isValidID(id) else { return "echo '@@failed bad id'" }
        return """
        before=$(cat \(directory)/\(id).last 2>/dev/null)
        bash \(directory)/\(id).sh >/dev/null 2>&1
        now=$(cat \(directory)/\(id).last 2>/dev/null)
        if [ -n "$now" ] && [ "$now" != "$before" ]; then echo "@@run $now"; else echo '@@skipped'; fi
        """
    }

    // MARK: Status

    public enum CronState: String, Sendable, Hashable { case on, paused, missing }

    public struct LastRun: Sendable, Hashable {
        public var run: DetachedRun
        public var status: DetachedRun.Status
        public var started: Date?
        /// Why a failed run failed, from the CLI's own error message or the last line on stderr.
        public var reason: String?
        public var failed: Bool { if case .ended(let code) = status { code != 0 && code != 143 } else { false } }
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public var schedule: AgentSchedule
        public var cron: CronState
        public var last: LastRun?
        /// When the newest log line is a skip: the time it was skipped.
        public var skipped: Date?
        public var id: String { schedule.id }
    }

    /// Per schedule: `@@sched <id>`, the definition, `@@cron on|paused|missing`, and for the last run
    /// `@@last <run id> <running|waiting <epoch>|ended <code>> <started epoch>` plus `@@reason <line>` when it failed,
    /// then `@@log <last log line>`.
    public static let listCommand = #"""
    cd ~/.deckhand/schedules 2>/dev/null || exit 0
    C=$(crontab -l 2>/dev/null)
    for f in *.json; do
      [ -f "$f" ] || continue; i=${f%.json}
      echo "@@sched $i"; printf '%s\n' "$(head -n 1 "$f")"
      if printf '%s\n' "$C" | grep -q "^[^#].* # deckhand-schedule $i\$"; then echo '@@cron on'
      elif printf '%s\n' "$C" | grep -q "# deckhand-schedule $i\$"; then echo '@@cron paused'
      else echo '@@cron missing'; fi
      r=$(cat "$i.last" 2>/dev/null)
      if [ -n "$r" ]; then
        R=~/.deckhand/runs/$r
        if [ -f "$R.exit" ]; then st="ended $(cat "$R.exit")"
        elif kill -0 "$(cat "$R.pid" 2>/dev/null)" 2>/dev/null; then
          if [ -f "$R.waiting" ]; then st="waiting $(cat "$R.waiting")"; else st=running; fi
        else st="ended 137"; fi
        s=$(grep -oE '"started":[0-9]+' "$R.meta" 2>/dev/null | grep -oE '[0-9]+')
        echo "@@last $r $st ${s:-0}"
        case "$st" in
          "ended 0"|"ended 143"|running|waiting*) ;;
          *) w=$(grep -E '"is_error":true|"type":"(turn\.failed|error)"' "$R.out" 2>/dev/null | tail -n 1)
             [ -n "$w" ] || w=$(grep -v '^[[:space:]]*$' "$R.err" 2>/dev/null | tail -n 1)
             [ -n "$w" ] || w=$(tail -n 1 "$R.out" 2>/dev/null)
             echo "@@reason $(printf '%s' "$w" | head -c 2000)" ;;
        esac
      fi
      echo "@@log $(tail -n 1 "$i.log" 2>/dev/null)"
    done
    """#

    public static func parseList(_ output: String) -> [Entry] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        var entries: [Entry] = []
        var pendingID: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@sched ") { pendingID = String(line.dropFirst(8)); continue }
            if let id = pendingID {
                pendingID = nil
                if var s = try? dec.decode(AgentSchedule.self, from: Data(line.utf8)) {
                    s.id = id
                    entries.append(Entry(schedule: s, cron: .missing))
                }
                continue
            }
            guard !entries.isEmpty else { continue }
            let i = entries.count - 1
            if line.hasPrefix("@@cron ") {
                entries[i].cron = CronState(rawValue: String(line.dropFirst(7))) ?? .missing
            } else if line.hasPrefix("@@last ") {
                let p = line.split(separator: " ").map(String.init)
                guard p.count >= 4 else { continue }
                let status: DetachedRun.Status
                var rest = 3
                switch p[2] {
                case "running": status = .running
                case "waiting": status = .waiting(until: Date(timeIntervalSince1970: Double(p[3]) ?? 0)); rest = 4
                default: status = .ended(exitCode: Int32(p[3]) ?? 1); rest = 4
                }
                let started = p.count > rest ? Double(p[rest]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } : nil
                entries[i].last = LastRun(run: DetachedRun(id: p[1]), status: status, started: started)
            } else if line.hasPrefix("@@reason ") {
                entries[i].last?.reason = reason(fromLine: String(line.dropFirst(9)))
            } else if line.hasPrefix("@@log ") {
                let p = line.dropFirst(6).split(separator: " ")
                if p.count >= 2, p[1] == "skipped", let t = Double(p[0]) { entries[i].skipped = Date(timeIntervalSince1970: t) }
            }
        }
        return entries.sorted { $0.schedule.name.localizedCaseInsensitiveCompare($1.schedule.name) == .orderedAscending }
    }

    /// The readable part of a CLI error line: Claude Code's `result`, Codex's `error.message` or `message`; plain text
    /// as it is. Cut to 300 characters.
    public static func reason(fromLine line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var text = t
        if let j = try? JSONValue.parse(t) {
            text = j["result"]?.stringValue ?? j["error"]?["message"]?.stringValue ?? j["message"]?.stringValue
                ?? j["error"]?.stringValue ?? t
        }
        return text.count > 300 ? String(text.prefix(299)) + "…" : text
    }
}
