import Foundation

/// GitHub Actions through the server's signed-in `gh`: recent runs of a repository, a run's jobs and the failing
/// part of its log, starting a workflow, re-running failed jobs, and a watcher on the server that pushes (ntfy)
/// when a run ends badly, so the phone hears about it while it sleeps.
public enum ActionsRuns {
    static let gh = #"GH=$(command -v gh 2>/dev/null || echo "$HOME/.local/bin/gh")"#

    public enum State: String, Sendable, Hashable {
        case queued, running, success, failure, cancelled, skipped, other
        public var isDone: Bool { ![.queued, .running].contains(self) }
    }

    static func state(status: String?, conclusion: String?) -> State {
        switch (status ?? "").lowercased() {
        case "queued", "waiting", "pending", "requested": return .queued
        case "in_progress": return .running
        default: break
        }
        switch (conclusion ?? "").lowercased() {
        case "success": return .success
        case "failure", "timed_out", "startup_failure", "action_required": return .failure
        case "cancelled": return .cancelled
        case "skipped", "neutral": return .skipped
        default: return .other
        }
    }

    public struct Run: Sendable, Hashable, Identifiable {
        public var id: Int
        public var title: String
        public var workflow: String
        public var branch: String
        public var event: String
        public var state: State
        public var created: Date?
        public var url: String
    }

    public struct Workflow: Sendable, Hashable, Identifiable {
        public var id: Int
        public var name: String
        public var path: String
        /// Has a `workflow_dispatch` trigger, so it can be started by hand.
        public var dispatchable: Bool
    }

    static func valid(_ repo: String) -> Bool {
        repo.split(separator: "/").count == 2 && !repo.contains("..")
            && repo.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./".contains($0)) }
    }

    /// The user's repositories, most recently pushed first.
    public static let reposCommand = """
    \(gh)
    [ -x "$GH" ] || { echo '@@nogh'; exit 0; }
    "$GH" repo list --limit 40 --json nameWithOwner,pushedAt --jq 'sort_by(.pushedAt) | reverse | .[].nameWithOwner' 2>&1
    """

    public static func parseRepos(_ out: String) -> [String]? {
        if out.contains("@@nogh") { return nil }
        return out.split(separator: "\n").map(String.init).filter(valid)
    }

    public static func runsCommand(repo: String, limit: Int = 30) -> String? {
        guard valid(repo) else { return nil }
        return "\(gh); \"$GH\" run list -R \(ShellQuote.quote(repo)) -L \(limit) --json databaseId,displayTitle,workflowName,status,conclusion,headBranch,event,createdAt,url 2>&1"
    }

    public static func parseRuns(_ out: String) -> [Run]? {
        guard let list = (try? JSONValue.parse(out))?.arrayValue else { return nil }
        let iso = ISO8601DateFormatter()
        return list.compactMap { r in
            guard let id = r["databaseId"]?.intValue else { return nil }
            return Run(id: id, title: r["displayTitle"]?.stringValue ?? "", workflow: r["workflowName"]?.stringValue ?? "",
                       branch: r["headBranch"]?.stringValue ?? "", event: r["event"]?.stringValue ?? "",
                       state: state(status: r["status"]?.stringValue, conclusion: r["conclusion"]?.stringValue),
                       created: r["createdAt"]?.stringValue.flatMap { iso.date(from: $0) }, url: r["url"]?.stringValue ?? "")
        }
    }

    /// Workflows and whether they can be started by hand (their file has `workflow_dispatch`).
    public static func workflowsCommand(repo: String) -> String? {
        guard valid(repo) else { return nil }
        let r = ShellQuote.quote(repo)
        return """
        \(gh)
        "$GH" workflow list -R \(r) --json id,name,path,state --jq '.[] | select(.state=="active") | [.id, .name, .path] | @tsv' 2>/dev/null | while IFS="$(printf '\\t')" read -r id name path; do
          d=no; "$GH" api "repos/\(repo)/contents/$path" --jq .content 2>/dev/null | base64 -d 2>/dev/null | grep -q workflow_dispatch && d=yes
          printf '%s\\t%s\\t%s\\t%s\\n' "$id" "$name" "$path" "$d"
        done
        """
    }

    public static func parseWorkflows(_ out: String) -> [Workflow] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, let id = Int(f[0]) else { return nil }
            return Workflow(id: id, name: f[1], path: f[2], dispatchable: f[3] == "yes")
        }
    }

    public static func dispatchCommand(repo: String, workflow: Int, ref: String) -> String? {
        guard valid(repo), !ref.isEmpty, !ref.contains(" ") else { return nil }
        return "\(gh); \"$GH\" workflow run \(workflow) -R \(ShellQuote.quote(repo)) --ref \(ShellQuote.quote(ref)) 2>&1 && echo @@ok"
    }

    public static func rerunCommand(repo: String, run: Int) -> String? {
        guard valid(repo) else { return nil }
        return "\(gh); \"$GH\" run rerun \(run) -R \(ShellQuote.quote(repo)) --failed 2>&1 && echo @@ok"
    }

    public struct Job: Sendable, Hashable, Identifiable {
        public var name: String
        public var state: State
        public var failedSteps: [String]
        public var id: String { name }
    }

    public struct Detail: Sendable, Hashable {
        public var jobs: [Job] = []
        /// The failing part of the log (job/step columns and timestamps dropped, the end kept).
        public var log = ""
    }

    public static func detailCommand(repo: String, run: Int) -> String? {
        guard valid(repo) else { return nil }
        let r = ShellQuote.quote(repo)
        return """
        \(gh)
        "$GH" run view \(run) -R \(r) --json jobs 2>&1 | tr -d '\\n'; echo
        echo '@@log'
        "$GH" run view \(run) -R \(r) --log-failed 2>/dev/null | cut -c1-1500 | head -c 3000000
        """
    }

    public static func parseDetail(_ out: String) -> Detail? {
        guard let marker = out.range(of: "\n@@log\n") ?? out.range(of: "\n@@log") else { return nil }
        guard let json = try? JSONValue.parse(String(out[..<marker.lowerBound])) else { return nil }
        var d = Detail()
        d.jobs = (json["jobs"]?.arrayValue ?? []).map { j in
            Job(name: j["name"]?.stringValue ?? "", state: state(status: j["status"]?.stringValue, conclusion: j["conclusion"]?.stringValue),
                failedSteps: (j["steps"]?.arrayValue ?? []).filter { state(status: $0["status"]?.stringValue, conclusion: $0["conclusion"]?.stringValue) == .failure }
                    .compactMap { $0["name"]?.stringValue })
        }
        d.log = digest(cleanLog(String(out[marker.upperBound...])))
        return d
    }

    /// The useful part of a long failed log: lines that look like errors (with a line around them), then the end.
    static func digest(_ log: String, maxHits: Int = 40, tail: Int = 40) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maxHits * 3 + tail else { return log }
        let pattern = #"(?i)\b(error|fatal|failed|failure|exception|panic|denied|not found|✘)\b|signal code|exit code [1-9]"#
        var keep = Set<Int>()
        var hits = 0
        for (i, l) in lines.enumerated() where hits < maxHits && l.range(of: pattern, options: .regularExpression) != nil {
            hits += 1
            for j in max(0, i - 1)...min(lines.count - 1, i + 1) { keep.insert(j) }
        }
        let tailStart = max(0, lines.count - tail)
        var out: [String] = []
        var last = -1
        for i in keep.sorted() where i < tailStart {
            if last >= 0 && i > last + 1 { out.append("…") }
            out.append(lines[i]); last = i
        }
        if !out.isEmpty { out.append("…") }
        out += lines[tailStart...]
        return out.joined(separator: "\n")
    }

    /// `gh run view --log-failed` lines are "job<TAB>step<TAB>timestamp text": keep the text.
    static func cleanLog(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            var text = cols.count == 3 ? String(cols[2]) : String(line)
            if let r = text.range(of: #"^\d{4}-\d\d-\d\dT[\d:.]+Z ?"#, options: .regularExpression) { text.removeSubrange(r) }
            return text
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Watches a run on the server (detached) and pushes to the ntfy topic when it fails, or when it ends at all.
    public static func watchCommand(repo: String, run: Int, title: String, topicURL: String, onlyFailures: Bool) -> String? {
        guard valid(repo), topicURL.hasPrefix("https://") else { return nil }
        let r = ShellQuote.quote(repo)
        let failed = ShellQuote.quote(String(localized: "CI failed: \(title)"))
        let passed = ShellQuote.quote(String(localized: "CI passed: \(title)"))
        let url = ShellQuote.quote("https://github.com/\(repo)/actions/runs/\(run)")
        let topic = ShellQuote.quote(topicURL)
        let body = """
        \(gh); "$GH" run watch \(run) -R \(r) --exit-status >/dev/null 2>&1; c=$?
        if [ "$c" -ne 0 ]; then curl -s -H "Click: "\(url) -H 'Tags: x' -d \(failed) \(topic) >/dev/null
        \(onlyFailures ? "" : "else curl -s -H \"Click: \"\(url) -H 'Tags: white_check_mark' -d \(passed) \(topic) >/dev/null\n")fi
        """
        return "nohup sh -c \(ShellQuote.quote(body)) >/dev/null 2>&1 & echo @@ok"
    }
}
