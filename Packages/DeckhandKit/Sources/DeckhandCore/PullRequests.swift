import Foundation

/// Pull requests on GitHub through the server's `gh` (signed in with Connect GitHub): the ones waiting for the
/// user's review and their own, a review with summary and risk notes, and comment / approve / merge.
public enum PullRequests {
    static let gh = #"GH=$(command -v gh 2>/dev/null || echo "$HOME/.local/bin/gh")"#

    public struct Item: Sendable, Hashable, Identifiable {
        public var repo: String
        public var number: Int
        public var title: String
        public var author: String
        public var updated: Date?
        public var isDraft: Bool
        public var url: String
        /// Waiting for the user's review (else: the user's own PR).
        public var reviewRequested: Bool
        public var id: String { "\(repo)#\(number)" }
    }

    static let fields = "number,title,repository,author,updatedAt,url,isDraft"

    /// "R<TAB>json" for PRs that ask for the user's review, "M<TAB>json" for the user's own open PRs.
    public static let listCommand = """
    \(gh)
    [ -x "$GH" ] || { echo '@@nogh'; exit 0; }
    printf 'R\\t'; "$GH" search prs --review-requested=@me --state=open --limit 50 --json \(fields) 2>&1 | tr -d '\\n'; echo
    printf 'M\\t'; "$GH" search prs --author=@me --state=open --limit 30 --json \(fields) 2>&1 | tr -d '\\n'; echo
    """

    public struct Listing: Sendable, Hashable {
        public var items: [Item] = []
        public var noGH = false
        public var error: String?
    }

    public static func parseList(_ output: String) -> Listing {
        var l = Listing()
        if output.contains("@@nogh") { l.noGH = true; return l }
        let iso = ISO8601DateFormatter()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "R" || parts[0] == "M" else { continue }
            guard let json = try? JSONValue.parse(parts[1]), let list = json.arrayValue else {
                l.error = parts[1].trimmingCharacters(in: .whitespaces)
                continue
            }
            for p in list {
                guard let n = p["number"]?.intValue, let repo = p["repository"]?["nameWithOwner"]?.stringValue else { continue }
                let item = Item(repo: repo, number: n, title: p["title"]?.stringValue ?? "", author: p["author"]?["login"]?.stringValue ?? "",
                                updated: p["updatedAt"]?.stringValue.flatMap { iso.date(from: $0) }, isDraft: p["isDraft"]?.boolValue ?? false,
                                url: p["url"]?.stringValue ?? "", reviewRequested: parts[0] == "R")
                if !l.items.contains(where: { $0.id == item.id }) { l.items.append(item) }
            }
        }
        l.items.sort { ($0.reviewRequested ? 0 : 1, -($0.updated?.timeIntervalSince1970 ?? 0)) < ($1.reviewRequested ? 0 : 1, -($1.updated?.timeIntervalSince1970 ?? 0)) }
        return l
    }

    static func valid(repo: String) -> Bool {
        let parts = repo.split(separator: "/")
        return parts.count == 2 && repo.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./".contains($0)) } && !repo.contains("..")
    }

    public struct Detail: Sendable, Hashable {
        public var title = ""
        public var body = ""
        public var author = ""
        public var base = ""
        public var head = ""
        public var additions = 0
        public var deletions = 0
        public var files: [(path: String, additions: Int, deletions: Int)] = []
        public var mergeable: String?
        public var reviewDecision: String?
        /// Checks: passed / failed / pending counts.
        public var checks = (passed: 0, failed: 0, pending: 0)
        public var diff = ""
        public var diffTruncated = false

        public static func == (a: Detail, b: Detail) -> Bool { a.title == b.title && a.diff == b.diff && a.mergeable == b.mergeable }
        public func hash(into h: inout Hasher) { h.combine(title); h.combine(diff) }
    }

    static let maxDiff = 300_000

    /// The PR's facts as JSON, a marker line, then its diff (cut at 300 kB).
    public static func detailCommand(repo: String, number: Int) -> String? {
        guard valid(repo: repo), number > 0 else { return nil }
        let r = ShellQuote.quote(repo)
        return """
        \(gh)
        "$GH" pr view \(number) -R \(r) --json title,body,author,baseRefName,headRefName,additions,deletions,files,mergeable,reviewDecision,statusCheckRollup 2>&1 | tr -d '\\n'; echo
        echo '@@diff'
        "$GH" pr diff \(number) -R \(r) 2>&1 | head -c \(maxDiff + 1)
        """
    }

    public static func parseDetail(_ output: String) -> Detail? {
        guard let marker = output.range(of: "\n@@diff\n") else { return nil }
        guard let json = try? JSONValue.parse(String(output[..<marker.lowerBound])), json["title"] != nil else { return nil }
        var d = Detail()
        d.title = json["title"]?.stringValue ?? ""
        d.body = json["body"]?.stringValue ?? ""
        d.author = json["author"]?["login"]?.stringValue ?? ""
        d.base = json["baseRefName"]?.stringValue ?? ""
        d.head = json["headRefName"]?.stringValue ?? ""
        d.additions = json["additions"]?.intValue ?? 0
        d.deletions = json["deletions"]?.intValue ?? 0
        d.files = (json["files"]?.arrayValue ?? []).map { ($0["path"]?.stringValue ?? "", $0["additions"]?.intValue ?? 0, $0["deletions"]?.intValue ?? 0) }
        d.mergeable = json["mergeable"]?.stringValue
        d.reviewDecision = json["reviewDecision"]?.stringValue
        for c in json["statusCheckRollup"]?.arrayValue ?? [] {
            let state = (c["conclusion"]?.stringValue ?? c["state"]?.stringValue ?? c["status"]?.stringValue ?? "").uppercased()
            switch state {
            case "SUCCESS", "NEUTRAL", "SKIPPED": d.checks.passed += 1
            case "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": d.checks.failed += 1
            default: d.checks.pending += 1
            }
        }
        var diff = String(output[marker.upperBound...])
        if diff.utf8.count > maxDiff { diff = String(diff.prefix(maxDiff)); d.diffTruncated = true }
        d.diff = diff
        return d
    }

    // MARK: - Review with AI

    public static let reviewInstructions = """
    You review a GitHub pull request for its maintainer, who reads on a phone. Answer in this exact shape:
    SUMMARY: two or three sentences on what the change does.
    RISKS:
    - one line per real risk (behaviour change, security, data loss, missing tests, breaking API); "- none found" if none.
    Be concrete, name files. No praise, no restating the diff.
    """

    /// A prompt that fits small models: facts, files, then as much diff as fits.
    public static func reviewPrompt(_ d: Detail, budget: Int = 12_000) -> String {
        var p = "Title: \(d.title)\nAuthor: \(d.author)  \(d.head) → \(d.base)  +\(d.additions) −\(d.deletions)\n"
        if !d.body.isEmpty { p += "Description:\n\(d.body.prefix(1500))\n" }
        p += "Files:\n" + d.files.prefix(60).map { "  \($0.path) (+\($0.additions) −\($0.deletions))" }.joined(separator: "\n") + "\n"
        let room = max(0, budget - p.count)
        p += "Diff\(d.diff.count > room ? " (first part)" : ""):\n" + d.diff.prefix(room)
        return p
    }

    public struct Review: Sendable, Hashable {
        public var summary: String
        public var risks: [String]
    }

    public static func parseReview(_ text: String) -> Review {
        var summary: [String] = [], risks: [String] = []
        var inRisks = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("SUMMARY:") { summary.append(String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)); inRisks = false; continue }
            if upper.hasPrefix("RISKS:") { inRisks = true; let rest = line.dropFirst(6).trimmingCharacters(in: .whitespaces); if !rest.isEmpty { risks.append(rest) }; continue }
            if inRisks, line.hasPrefix("-") || line.hasPrefix("•") || line.hasPrefix("*") {
                let r = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !r.isEmpty, r.lowercased() != "none found" { risks.append(r) }
            } else if !inRisks, !line.isEmpty { summary.append(line) }
        }
        return Review(summary: summary.joined(separator: " ").trimmingCharacters(in: .whitespaces), risks: risks)
    }

    // MARK: - Actions

    public enum Verdict: String, Sendable, CaseIterable { case comment, approve, requestChanges = "request-changes" }
    public enum MergeMethod: String, Sendable, CaseIterable { case squash, merge, rebase }

    public static func reviewCommand(repo: String, number: Int, verdict: Verdict, body: String) -> String? {
        guard valid(repo: repo), number > 0 else { return nil }
        if verdict != .approve && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let b = body.isEmpty ? "" : " -b \(ShellQuote.quote(body))"
        return "\(gh); \"$GH\" pr review \(number) -R \(ShellQuote.quote(repo)) --\(verdict.rawValue)\(b) 2>&1 && echo @@ok"
    }

    public static func mergeCommand(repo: String, number: Int, method: MergeMethod, deleteBranch: Bool) -> String? {
        guard valid(repo: repo), number > 0 else { return nil }
        return "\(gh); \"$GH\" pr merge \(number) -R \(ShellQuote.quote(repo)) --\(method.rawValue)\(deleteBranch ? " --delete-branch" : "") 2>&1 && echo @@ok"
    }
}
