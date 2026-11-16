import Foundation

/// The agent looks into a failure by itself: when an uptime check fails, a systemd service crashes or a disk fills
/// up, the server starts a read-only Claude Code or Codex run that finds the cause and proposes a fix. The cause and
/// the fix arrive as a push with Apply and Dismiss; only an approved fix changes the server.
///
/// Everything runs on the server (`~/.deckhand/investigate/`, a cron line `# deckhand-investigate` every minute),
/// so the phone can be off. Each run is an ordinary detached run, so it shows up under Background tasks with its
/// action log. A daily limit caps the automatic runs, and house rules are checked before a fix is applied.
public enum AutoInvestigate {
    public static let directory = "~/.deckhand/investigate"
    static let cronTag = "# deckhand-investigate"

    public struct Config: Codable, Sendable, Hashable {
        public var cli: ServerCLI
        public var model: String?
        public var effort: String?
        /// The house rules' spending cap (Claude Code only).
        public var maxBudgetUSD: Double?
        public var uptime: Bool
        public var services: Bool
        public var disk: Bool
        /// A disk counts as full from this share on.
        public var diskPercent: Int
        /// At most this many investigations start in 24 hours.
        public var maxPerDay: Int
        /// The ntfy topic URL; answers come back on `<topic>-reply`.
        public var topic: String
        /// The app's id for this server (for the link in the push).
        public var server: String
        /// The server's name in the push.
        public var name: String
        /// GitHub repositories whose failed Actions runs start an investigation (needs `gh` signed in on the server).
        public var ciRepos: [CIRepo]?
        /// Minutes between two looks at GitHub Actions.
        public var ciMinutes: Int?

        public struct CIRepo: Codable, Sendable, Hashable, Identifiable {
            /// `owner/name`
            public var repo: String
            /// Where it is checked out on the server (the agent works and opens the pull request there).
            public var dir: String
            public var id: String { repo }
            public init(repo: String, dir: String) { self.repo = repo; self.dir = dir }
            public var isValid: Bool {
                repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
                    && dir.range(of: #"^(~|/)[A-Za-z0-9_./~@+-]*$"#, options: .regularExpression) != nil && !dir.contains("..")
            }
        }

        public var repos: [CIRepo] { (ciRepos ?? []).filter(\.isValid) }

        public init(
            cli: ServerCLI, options: CLIOptions = .init(), uptime: Bool = true, services: Bool = true, disk: Bool = true,
            diskPercent: Int = 90, maxPerDay: Int = 3, topic: String, server: String, name: String
        ) {
            self.cli = cli; model = options.model; effort = options.effort; maxBudgetUSD = options.maxBudgetUSD
            self.uptime = uptime; self.services = services; self.disk = disk
            self.diskPercent = min(max(diskPercent, 50), 99); self.maxPerDay = min(max(maxPerDay, 1), 20)
            self.topic = topic; self.server = server; self.name = name
        }

        public var options: CLIOptions { CLIOptions(model: model, effort: effort, maxBudgetUSD: maxBudgetUSD) }

        /// The settings file; `engine` is the name the task list shows.
        var json: String {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? enc.encode(self), case .object(var obj)? = try? JSONValue.parse(data) else { return "{}" }
            obj["engine"] = .string(cli.displayName)
            return JSONValue.object(obj).jsonString()
        }
    }

    public enum Kind: String, Sendable, Codable, Hashable { case uptime, service, disk, ci }

    public enum State: String, Sendable, Codable, Hashable {
        /// The agent is looking.
        case running
        /// Cause and fix are waiting for the owner.
        case proposed
        /// The agent found the cause; nothing on the server needs to change.
        case nofix
        /// The run didn't come back with an answer.
        case failed
        /// Not looked into: the daily limit was reached.
        case limited
        /// The approved fix is being applied.
        case applying
        case fixed
        /// The fix ran, but the problem is still there.
        case stillfailing
        /// A house rule stopped the fix.
        case blocked
        case dismissed
        /// The problem went away before anyone approved the fix.
        case resolved

        public var isOpen: Bool { self == .running || self == .proposed || self == .applying }
    }

    public struct Investigation: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        /// `service:nginx.service`, `disk:/`, `uptime:<check id>`.
        public var key: String
        public var kind: Kind
        /// The English title the push uses; the app shows its own from `kind` and `arg`.
        public var title: String
        /// The unit, the mount or the check's URL.
        public var arg: String
        /// The uptime check's name.
        public var name: String?
        /// How full the disk was.
        public var percent: Int?
        public var started: Date
        public var updated: Date?
        public var status: State
        public var cause: String?
        public var fix: String?
        /// Answers from the lock screen carry this.
        public var fp: String?
        /// The fix holds a command that can't easily be undone: it needs the app (and Face ID), not just the push.
        public var risky: Bool?
        /// The investigation's run and the run that applied the fix (`~/.deckhand/runs/<id>`).
        public var run: String?
        public var applyRun: String?
        /// Why it failed, the house rule that blocked the fix, or why the fix wasn't applied.
        public var note: String?
        /// The agent's last line after applying the fix.
        public var result: String?
        /// Who approved or dismissed (device name).
        public var who: String?
        /// A failed CI run: its page, branch and workflow (`name`); `arg` is the repository.
        public var url: String?
        public var branch: String?
    }

    public struct Status: Sendable, Hashable {
        public var installed = false
        public var python = true
        public var config: Config?
        /// Newest first.
        public var investigations: [Investigation] = []

        /// Investigations started in the last 24 hours (the ones the daily limit counts).
        public func startedToday(now: Date = Date()) -> Int {
            investigations.filter { $0.status != .limited && now.timeIntervalSince($0.started) < 86_400 }.count
        }
    }

    // MARK: - Server side

    /// What every investigation starts with, per kind. `'@@ARG@@'` is replaced with the quoted unit, mount or URL.
    static var evidence: [Kind: String] {
        [
            .uptime: Incident.evidenceCommand(url: "@@ARG@@"),
            .service: """
            S() { printf '\\n@@section %s\\n' "$1"; }
            S "Service status"
            systemctl status '@@ARG@@' --no-pager -l -n 0 2>&1 | head -n 30
            S "Service log"
            journalctl -u '@@ARG@@' -n 60 --no-pager -q -o short 2>&1 | tail -n 60
            S "Unit file"
            systemctl cat '@@ARG@@' --no-pager 2>&1 | head -n 60
            S "Load and memory"
            uptime 2>/dev/null; free -m 2>/dev/null
            S "Disk"
            df -hP 2>/dev/null | awk 'NR==1 || $5+0 >= 80'
            S "Recent changes"
            tail -n 6 /var/log/apt/history.log 2>/dev/null | grep -E '^(Start-Date|Commandline)'
            true
            """,
            .disk: """
            S() { printf '\\n@@section %s\\n' "$1"; }
            T=; command -v timeout >/dev/null 2>&1 && T="timeout 60"
            S "Disk"
            df -hP '@@ARG@@' 2>&1; df -iP '@@ARG@@' 2>/dev/null | tail -n 1
            S "Largest folders"
            $T du -xh --max-depth=2 '@@ARG@@' 2>/dev/null | sort -rh | head -n 25
            S "Big files"
            $T find '@@ARG@@' -xdev -type f -size +200M -printf '%s %p\\n' 2>/dev/null | sort -rn | head -n 10 | awk '{printf "%d MB %s\\n", $1/1048576, $2}'
            S "System journal"
            journalctl --disk-usage 2>&1 | tail -n 1
            S "Containers"
            command -v docker >/dev/null 2>&1 && $T docker system df 2>/dev/null
            true
            """,
        ]
    }

    /// The first turn: read-only, the cause in one sentence first, the fix in a block the server can pick up.
    static let promptTemplate = """
        Deckhand noticed a problem on this server and asked you to look into it: @@TITLE@@.

        Evidence collected on this server just now:

        @@EVIDENCE@@

        Find the cause. Look further where the evidence points (status, logs, config, recent changes). You are read-only: \
        don't change anything. The owner approves a fix from their phone first.

        Answer in this shape, in plain words:
        Cause: <the cause in one sentence>
        <a short explanation>
        ## \(Incident.fixHeading)
        ```sh
        <the exact shell commands and nothing else; use sudo -n where root is needed>
        ```
        If nothing on this server needs to change, write "No fix needed" instead of the fix section.
        """

    /// The approved second run: exactly the fix that was shown, then a check.
    static let applyTemplate = """
        The owner approved this fix for a problem on this server (@@TITLE@@; cause: @@CAUSE@@). Run exactly these \
        commands, in this order, and nothing else that changes the server:
        ```sh
        @@FIX@@
        ```
        If a command fails, stop and say why. Then check whether the problem is gone and answer in one line.
        """

    /// A failed GitHub Actions run: the failing log and the commit's diff, a diagnosis and a change.
    static let ciPromptTemplate = """
        A GitHub Actions run failed: @@TITLE@@ (@@URL@@). You are in the repository's checkout on this server.

        @@EVIDENCE@@

        Find the cause. Read the code where the log points. Don't change anything yet: the owner approves a pull \
        request from their phone first.

        Answer in this shape, in plain words:
        Cause: <the cause in one sentence>
        <a short explanation>
        ## \(Incident.fixHeading)
        ```diff
        <the change as a unified diff, or the exact commands if it is not a code change>
        ```
        If the failure is flaky or outside the code (a service outage, a missing secret), say so instead of the fix section.
        """

    /// The approved second run for CI: the change on a new branch and a pull request, never a push to the branch itself.
    static let ciApplyTemplate = """
        The owner approved this fix for the failed CI run "@@TITLE@@" (cause: @@CAUSE@@).
        In the checkout of @@REPO@@ (clone it with `gh repo clone @@REPO@@` into this folder first if it isn't here): \
        fetch, create a new branch @@BRANCH@@ from origin/@@BASE@@, make exactly this change and \
        nothing else, commit it ("Fix CI: @@TITLE@@"), push the new branch and open a pull request into @@BASE@@ with \
        `gh pr create`, explaining the cause in its description. Never push to @@BASE@@ itself.
        ```diff
        @@FIX@@
        ```
        The last line of your answer is the pull request's URL.
        """

    /// The house rules' list of commands that can't easily be undone, taken from the checker so both agree.
    static var riskyLine: String {
        let s = HouseRules.hookScript
        guard let start = s.range(of: "RISKY = re.compile("), let end = s[start.upperBound...].range(of: ", re.I)\n") else {
            return "RISKY = re.compile(r\"$^\")"
        }
        return String(s[start.lowerBound..<end.lowerBound]) + ", re.I)"
    }

    static func pyString(_ s: String) -> String { JSONValue.string(s).jsonString() }

    /// The checker cron runs every minute, and the steps around each run.
    static var script: String {
        let ev = JSONValue.object(Dictionary(uniqueKeysWithValues: evidence.map { ($0.key.rawValue, JSONValue.string($0.value)) })).jsonString()
        return #"""
#!/usr/bin/env python3
# Deckhand: looks into failures by itself. Managed by the Deckhand app; change it there.
#   inv.py tick                   cron, every minute: answers from the phone, new failures, new runs
#   inv.py finish ID CODE KIND    a run ended (KIND start or apply): read the answer, push it
#   inv.py apply ID WHO [app]     the owner approved the fix ("app": approved in the app with Face ID)
#   inv.py dismiss ID WHO
import fcntl, hashlib, json, os, re, shlex, shutil, subprocess, sys, time, urllib.parse, urllib.request

D = os.path.expanduser("~/.deckhand/investigate")
RUNS = os.path.expanduser("~/.deckhand/runs")
RULES = os.path.expanduser("~/.deckhand/rules")
UPTIME = os.path.expanduser("~/.deckhand/uptime")
CONFIG = os.path.join(D, "config.json")
STATE = os.path.join(D, "state.json")
EVIDENCE = json.loads(\#(pyString(ev)))
PROMPT = \#(pyString(promptTemplate))
APPLY = \#(pyString(applyTemplate))
CI_PROMPT = \#(pyString(ciPromptTemplate))
CI_APPLY = \#(pyString(ciApplyTemplate))
GH = shutil.which("gh") or os.path.expanduser("~/.local/bin/gh")
\#(riskyLine)
OPEN = ("running", "applying")
KEEP = 100


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def save(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, sort_keys=True, separators=(",", ":"))
        f.write("\n")
    os.replace(tmp, path)


class Lock:
    def __enter__(self):
        self.f = open(os.path.join(D, ".lock"), "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)

    def __exit__(self, *a):
        self.f.close()


def records():
    out = []
    for n in os.listdir(D):
        if n.startswith("i-") and n.endswith(".json"):
            r = load(os.path.join(D, n), None)
            if r:
                out.append(r)
    return sorted(out, key=lambda r: r.get("started", 0))


def record(iid):
    if not re.match(r"^i-[0-9]{8}-[0-9]{6}(-[0-9]+)?$", iid or ""):
        return None
    return load(os.path.join(D, iid + ".json"), None)


def put(r):
    r["updated"] = int(time.time())
    save(os.path.join(D, r["id"] + ".json"), r)


def sh(cmd, timeout=60):
    try:
        return subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL).stdout
    except Exception:
        return ""


def probe(url, expect, keyword):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Deckhand uptime"})
        with urllib.request.urlopen(req, timeout=20) as r:
            code, body = r.status, r.read(1 << 20).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        code, body = e.code, ""
    except Exception:
        return False
    lo, _, hi = expect.partition("-")
    ok = int(lo) <= code <= int(hi or lo)
    return ok and (not keyword or keyword in body)


GH_ERROR = [""]


def gh(args, cwd=None, timeout=60):
    """stdout of the GitHub CLI, or None (the reason in GH_ERROR[0])."""
    try:
        p = subprocess.run([GH] + args, capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL, cwd=cwd,
                           encoding="utf-8", errors="replace")
        GH_ERROR[0] = ([l for l in p.stderr.splitlines() if l.strip()] or [""])[-1][:300]
        return p.stdout if p.returncode == 0 else None
    except Exception as e:
        GH_ERROR[0] = str(e)[:300]
        return None


def poll_ci(cfg, state):
    """New failed GitHub Actions runs since the last look go to state["ciPending"]. The first look only remembers
    where things stand, so old failures don't start anything."""
    repos = [r for r in cfg.get("ciRepos") or [] if re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", r.get("repo", ""))]
    if not repos or not os.path.exists(GH):
        return
    minutes = cfg.get("ciMinutes")
    minutes = 3 if minutes is None else max(0, int(minutes))
    if minutes and time.time() - state.get("ciPolled", 0) < 60 * minutes - 5:
        return
    state["ciPolled"] = int(time.time())
    seen, pending = state.setdefault("ciSeen", {}), state.setdefault("ciPending", {})
    for r in repos:
        out = gh(["run", "list", "-R", r["repo"], "--status", "failure", "--limit", "10",
                  "--json", "databaseId,displayTitle,headBranch,headSha,workflowName,url"])
        if out is None:
            continue
        try:
            runs = json.loads(out)
        except Exception:
            continue
        top = max([x.get("databaseId", 0) for x in runs] + [0])
        if r["repo"] not in seen:
            seen[r["repo"]] = top
            continue
        for x in sorted(runs, key=lambda x: x.get("databaseId", 0)):
            rid = x.get("databaseId", 0)
            if rid > seen[r["repo"]]:
                pending["ci:%s:%d" % (r["repo"], rid)] = {
                    "kind": "ci", "arg": r["repo"], "dir": r.get("dir") or "~", "runId": rid, "name": x.get("workflowName") or "CI",
                    "branch": x.get("headBranch") or "", "sha": x.get("headSha") or "", "url": x.get("url") or "",
                    "title": "CI failed: %s on %s" % (x.get("workflowName") or "CI", x.get("headBranch") or "?")}
        seen[r["repo"]] = max(seen[r["repo"]], top)


ANSI = re.compile(r"(\x1b|\^\[)\[[0-9;]*[A-Za-z]")
STAMP = re.compile(r"^\S*\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z ?")
PASSED = re.compile(r"^\s*[✔◇]|\bpassed after\b|\b(started|skipped)\.?$|^\s*ok \d|\bPASS(ED)?\b|^\[\d+/\d+\] Compiling")
ERRORISH = re.compile(r"##\[error\]|✘|\bFAIL(ED|URE)?\b|(?i:\berror\b|\bfailed\b|\bfailure\b|\btraceback\b|\bexception\b|\bpanic\b|exit code [1-9])")


def log_digest(text, context=2, tail=40, limit=7000):
    """The useful part of a failed job's log (`gh run view --log-failed`): job and step columns and timestamps go;
    first the error lines with a little context, then the end of the log; lines of things that passed are left out."""
    lines = []
    for raw in text.splitlines():
        parts = raw.split("\t", 2)
        line = parts[2] if len(parts) == 3 else raw
        step = parts[1] if len(parts) == 3 else ""
        line = STAMP.sub("", ANSI.sub("", line.replace("\ufeff", ""))).rstrip()
        if line and not PASSED.search(line):
            lines.append((step, line))

    def block(indices):
        out, last, step_now = [], -2, None
        for i in sorted(indices):
            step, line = lines[i]
            if i != last + 1 and out:
                out.append("…")
            if step and step != step_now:
                out.append("== %s" % step)
                step_now = step
            out.append(line)
            last = i
        return "\n".join(out)
    errors = set()
    for i, (_, line) in enumerate(lines):
        if ERRORISH.search(line):
            errors.update(range(max(0, i - context), min(len(lines), i + context + 1)))
    head = block(errors)
    if len(head) > limit * 2 // 3:
        head = head[:limit * 2 // 3] + "\n…"
    end = block(set(range(max(0, len(lines) - tail), len(lines))) - errors)
    room = limit - len(head)
    if len(end) > room:
        end = "…\n" + end[-max(0, room):]
    return (head + ("\n\n--- end of the log ---\n" + end if end.strip() else "")).strip()


def ci_evidence(t):
    log = gh(["run", "view", str(t["runId"]), "-R", t["arg"], "--log-failed"], timeout=120)
    why = GH_ERROR[0] if log is None else ""
    log = log or ""
    sections = ["### Run\n```\n%s\nworkflow %s, branch %s, commit %s\n%s\n```" % (t["title"], t["name"], t["branch"], t["sha"][:12], t["url"])]
    sections.append("### Failing steps (digest of the log)\n```\n%s\n```" % (log_digest(log) if log.strip() else "(the log couldn't be read%s)" % (": " + why if why else "")))
    d = os.path.expanduser(t.get("dir") or "~")
    diff = ""
    if os.path.isdir(os.path.join(d, ".git")) and re.match(r"^[0-9a-f]{7,40}$", t["sha"]):
        sh("git -C %s fetch -q origin %s 2>/dev/null" % (shlex.quote(d), t["sha"]), 60)
        diff = sh("git -C %s show --stat --patch -U3 --format=fuller %s 2>/dev/null | head -n 400" % (shlex.quote(d), t["sha"]), 60)
    if not diff.strip():
        diff = gh(["api", "repos/%s/commits/%s" % (t["arg"], t["sha"]), "--jq", '.files[] | "--- " + .filename + "\\n" + (.patch // "")']) or ""
        diff = "\n".join(diff.splitlines()[:400])
    sections.append("### The commit's change\n```diff\n%s\n```" % (diff.strip() or "(not available)"))
    return "\n\n".join(sections)


def triggers(cfg, state=None):
    """Every problem right now, by key."""
    found = dict((state or {}).get("ciPending") or {})
    if cfg.get("uptime", True):
        try:
            with open(os.path.join(UPTIME, "checks.tsv")) as f:
                lines = f.read().splitlines()
        except Exception:
            lines = []
        for line in lines:
            p = line.split("\t")
            if len(p) < 5 or not re.match(r"^[A-Za-z0-9]+$", p[0]):
                continue
            try:
                with open(os.path.join(UPTIME, p[0] + ".state")) as f:
                    down = f.read().strip() == "0"
            except Exception:
                down = False
            if down:
                found["uptime:" + p[0]] = {"kind": "uptime", "arg": p[2], "name": p[1], "expect": p[4],
                                           "keyword": p[5] if len(p) > 5 else "", "title": "Uptime check %s is failing" % p[1]}
    if cfg.get("services", True) and shutil.which("systemctl"):
        for line in sh("systemctl --failed --no-legend --plain 2>/dev/null").splitlines():
            unit = (line.split() or [""])[0]
            if re.match(r"^[A-Za-z0-9@._:\\-]+$", unit):
                found["service:" + unit] = {"kind": "service", "arg": unit, "title": "%s failed" % unit}
    if cfg.get("disk", True):
        limit = int(cfg.get("diskPercent") or 90)
        out = sh("df -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null || df -P 2>/dev/null")
        for line in out.splitlines()[1:]:
            p = line.split()
            if len(p) < 6 or not p[4].endswith("%") or not p[4][:-1].isdigit():
                continue
            used, mount = int(p[4][:-1]), " ".join(p[5:])
            if used >= limit and mount.startswith("/"):
                found["disk:" + mount] = {"kind": "disk", "arg": mount, "percent": used, "title": "Disk %s is %d%% full" % (mount, used)}
    return found


def still_failing(cfg, r):
    kind, arg = r.get("kind"), r.get("arg") or ""
    if kind == "uptime":
        return not probe(arg, r.get("expect") or "200-399", r.get("keyword") or "")
    if kind == "service":
        return subprocess.run(["systemctl", "is-failed", "--quiet", arg], stdin=subprocess.DEVNULL).returncode == 0
    if kind == "ci":
        return False
    return r.get("key") in triggers(cfg)


def run_alive(rid):
    base = os.path.join(RUNS, rid)
    if os.path.exists(base + ".exit"):
        return False
    try:
        with open(base + ".pid") as f:
            os.kill(int(f.read().strip()), 0)
        return True
    except Exception:
        return False


def exit_code(rid):
    try:
        with open(os.path.join(RUNS, rid + ".exit")) as f:
            return int(f.read().strip())
    except Exception:
        return None


def meta(rid, title, cfg, directory="~"):
    os.makedirs(RUNS, exist_ok=True)
    with open(os.path.join(RUNS, rid + ".meta"), "w") as f:
        f.write(json.dumps({"title": title, "engine": cfg.get("engine") or "", "directory": directory, "started": int(time.time())}) + "\n")


def workdir(directory):
    """The checkout when it exists on this server, else the home folder."""
    d = os.path.expanduser(directory or "~")
    return directory if os.path.isdir(d) else "~"


def launch(script, rid, iid, prompt, directory="~"):
    pf = os.path.join(D, "%s.%s.prompt" % (iid, script.split(".")[0]))
    with open(pf, "w") as f:
        f.write(prompt)
    env = dict(os.environ, RID=rid, IID=iid, PF=pf, DIR=os.path.expanduser(directory))
    subprocess.run(["bash", os.path.join(D, script)], env=env, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)


def evidence(t):
    cmd = EVIDENCE.get(t["kind"], "").replace("'@@ARG@@'", shlex.quote(t["arg"]))
    sections, cur = [], None
    for line in sh(cmd, 150).splitlines():
        if line.startswith("@@section "):
            cur = [line[10:], []]
            sections.append(cur)
        elif cur is not None:
            cur[1].append(line)
    out = []
    for title, lines in sections:
        text = "\n".join(lines).strip()
        if text:
            out.append("### %s\n```\n%s\n```" % (title, text[-2500:]))
    return "\n\n".join(out) or "(none)"


def new_id():
    base = "i-" + time.strftime("%Y%m%d-%H%M%S")
    iid, n = base, 1
    while os.path.exists(os.path.join(D, iid + ".json")):
        iid, n = "%s-%d" % (base, n), n + 1
    return iid


def start(cfg, key, t):
    iid = new_id()
    rid = "inv-" + iid[2:]
    r = dict(t, id=iid, key=key, started=int(time.time()), status="running", run=rid)
    put(r)
    if t["kind"] == "ci":
        d = workdir(t.get("dir"))
        meta(rid, "Investigate: " + t["title"], cfg, d)
        prompt = CI_PROMPT.replace("@@TITLE@@", t["title"]).replace("@@URL@@", t.get("url") or "").replace("@@EVIDENCE@@", ci_evidence(t))
        if d == "~":
            prompt = prompt.replace("You are in the repository's checkout on this server.",
                                    "The repository %s isn't checked out on this server; read the code with `gh` if you need it." % t["arg"])
        launch("start.sh", rid, iid, prompt, d)
        return
    meta(rid, "Investigate: " + t["title"], cfg)
    launch("start.sh", rid, iid, PROMPT.replace("@@TITLE@@", t["title"]).replace("@@EVIDENCE@@", evidence(t)))


def answer(rid):
    """(final text, error) from a run's output, for Claude Code and Codex."""
    text, err = None, None
    try:
        with open(os.path.join(RUNS, rid + ".out"), errors="replace") as f:
            lines = f.read().splitlines()
    except Exception:
        lines = []
    for line in lines:
        try:
            j = json.loads(line)
        except Exception:
            continue
        if not isinstance(j, dict):
            continue
        kind = j.get("type")
        if kind == "result":
            if j.get("is_error"):
                err = str(j.get("result") or "The agent stopped with an error.")
            elif isinstance(j.get("result"), str):
                text = j["result"]
        elif kind == "item.completed" and isinstance(j.get("item"), dict) and j["item"].get("type") == "agent_message":
            text = j["item"].get("text") or text
        elif kind in ("turn.failed", "error"):
            e = j.get("error")
            err = (e.get("message") if isinstance(e, dict) else e) or j.get("message") or "The agent stopped with an error."
    if text is None and err is None:
        try:
            with open(os.path.join(RUNS, rid + ".err"), errors="replace") as f:
                rest = [l for l in f.read().splitlines() if l.strip()]
            err = rest[-1][:300] if rest else None
        except Exception:
            pass
    return text, err


def cause_of(text):
    m = re.search(r"(?im)^[\s*_>#-]*cause[\s*_]*:[\s*_]*(.+)$", text)
    line = m.group(1) if m else next((l for l in text.splitlines() if l.strip() and not l.lstrip().startswith(("#", "`"))), "")
    line = re.sub(r"[*_`]+", "", line).strip()
    return line if len(line) <= 280 else line[:279] + "…"


def fix_of(text):
    h = re.search(r"(?mi)^#{1,4}\s*Suggested fix", text)
    if not h:
        return None
    m = re.search(r"```[a-zA-Z]*\n(.*?)```", text[h.end():], re.S)
    fix = m.group(1).strip() if m else ""
    return fix or None


def reply_topic(cfg):
    topic = (cfg.get("topic") or "").rstrip("/")
    return topic + "-reply" if re.match(r"^https?://[^\s,;]+/[^/\s,;]+$", topic) else None


def push(cfg, r, title, message, tags, priority=3, actions=None):
    """A push through ntfy's JSON API (UTF-8 safe); the tap opens the investigation in the app."""
    topic = (cfg.get("topic") or "").rstrip("/")
    m = re.match(r"^(https?://[^\s,;]+)/([^/\s,;]+)$", topic)
    if not m:
        return
    body = {"topic": m.group(2), "title": "%s · %s" % (title, cfg.get("name") or os.uname().nodename),
            "message": message[:3500], "tags": [tags], "priority": priority}
    if cfg.get("server") and r:
        body["click"] = "deckhand://investigation/%s/%s" % (cfg["server"], r["id"])
    if actions:
        body["actions"] = actions
    try:
        req = urllib.request.Request(m.group(1), data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=10).read()
    except Exception:
        pass


def short(fix, limit=300):
    return fix if len(fix) <= limit else fix[:limit - 1] + "…"


def finish(cfg, r, code, kind):
    if kind == "apply":
        if r.get("status") != "applying":
            return
        text, err = answer(r.get("applyRun") or "")
        last = [l for l in (text or "").splitlines() if l.strip()]
        r["result"] = (last[-1] if last else (err or ""))[:300]
        if r.get("kind") == "ci":
            m = re.search(r"https://github\.com/[^\s)]+/pull/\d+", text or "")
            if m:
                r.update(status="fixed", result=m.group(0), note="Pull request opened")
                push(cfg, r, "Pull request opened: " + r["title"], m.group(0), "white_check_mark")
            else:
                r.update(status="failed", note=(err or r["result"] or "No pull request was opened.")[:300])
                push(cfg, r, "No pull request: " + r["title"], r["note"], "warning")
            put(r)
            return
        if still_failing(cfg, r):
            r["status"] = "stillfailing"
            push(cfg, r, "Still failing: " + r["title"], "The fix ran, but the problem is still there. " + r["result"], "warning", 4)
        else:
            r["status"] = "fixed"
            push(cfg, r, "Fixed: " + r["title"], r["result"] or "The problem is gone.", "white_check_mark")
        put(r)
        return
    if r.get("status") != "running":
        return
    if code == 143:
        r["status"], r["note"] = "failed", "Stopped."
        put(r)
        return
    text, err = answer(r.get("run") or "")
    if not text:
        r["status"], r["note"] = "failed", (err or "The agent didn't answer.")[:300]
        put(r)
        push(cfg, r, "Couldn't look into it: " + r["title"], r["note"], "warning")
        return
    r["cause"] = cause_of(text)
    fix = fix_of(text)
    if not fix:
        r["status"] = "nofix"
        put(r)
        push(cfg, r, r["title"], r["cause"] + "\n\nNothing on the server needs to change.", "mag")
        return
    r.update(status="proposed", fix=fix, fp=hashlib.sha256((r["id"] + "\n" + fix).encode()).hexdigest()[:12],
             risky=False if r.get("kind") == "ci" else bool(RISKY.search(fix)))
    put(r)
    reply = reply_topic(cfg)
    link = "deckhand://investigation/%s/%s" % (cfg.get("server") or "-", r["id"])
    actions = []
    if reply:
        if r["risky"]:
            actions.append({"action": "view", "label": "Review in Deckhand", "url": link, "clear": True})
        else:
            actions.append({"action": "http", "label": "Open PR" if r.get("kind") == "ci" else "Apply", "url": reply, "method": "POST",
                            "body": "apply:" + r["fp"], "clear": True})
        actions.append({"action": "http", "label": "Dismiss", "url": reply, "method": "POST", "body": "dismiss:" + r["fp"], "clear": True})
    push(cfg, r, r["title"], "%s\n\nFix:\n%s" % (r["cause"], short(fix)), "mag", 4, actions)


def rule_block(fix):
    """The house rule the fix breaks, if any (the same checker every agent run goes through)."""
    if not os.path.exists(os.path.join(RULES, "hook.py")):
        return None
    try:
        sys.path.insert(0, RULES)
        import hook
    except Exception:
        return "The house rules checker can't be read"
    try:
        rules = hook.load_rules()
    except Exception:
        return "The house rules file is damaged"
    if not rules:
        return None
    hit = hook.check(rules, "deckhand", {"tool_name": "run_command", "tool_input": {"command": fix}, "cwd": os.path.expanduser("~")}, time.time())
    return hit[1] if hit else None


def read_only_rules():
    try:
        sys.path.insert(0, RULES)
        import hook
        rules = hook.load_rules() or {}
    except Exception:
        return None
    return "Read-only mode: agents may look, not change" if rules.get("readOnly") else None


def apply(cfg, r, who, in_app):
    if r.get("status") != "proposed" or not r.get("fix"):
        return "@@state " + str(r.get("status"))
    if r.get("risky") and not in_app:
        # A command that can't easily be undone needs Face ID in the app, not just a tap on the push.
        r["note"] = "This fix needs approval in the app."
        put(r)
        return "@@needsapp"
    block = rule_block(r["fix"]) if r.get("kind") != "ci" else read_only_rules()
    if block:
        r.update(status="blocked", note=block, who=who)
        put(r)
        push(cfg, r, "Not applied: " + r["title"], "House rule: " + block, "no_entry")
        return "@@blocked " + block
    rid = "inv-" + r["id"][2:] + "-fix"
    r.update(status="applying", applyRun=rid, who=who, note=None)
    put(r)
    if r.get("kind") == "ci":
        d = workdir(r.get("dir"))
        meta(rid, "Pull request: " + r["title"], cfg, d)
        branch = "deckhand/fix-ci-%s" % r.get("runId", r["id"][2:])
        prompt = (CI_APPLY.replace("@@TITLE@@", r["title"]).replace("@@CAUSE@@", r.get("cause") or "")
                  .replace("@@BRANCH@@", branch).replace("@@BASE@@", r.get("branch") or "main").replace("@@FIX@@", r["fix"])
                  .replace("@@REPO@@", r.get("arg") or ""))
        launch("apply.sh", rid, r["id"], prompt, d)
        return "@@applying " + rid
    meta(rid, "Fix: " + r["title"], cfg)
    launch("apply.sh", rid, r["id"], APPLY.replace("@@TITLE@@", r["title"]).replace("@@CAUSE@@", r.get("cause") or "").replace("@@FIX@@", r["fix"]))
    return "@@applying " + rid


def replies(cfg, state):
    reply = reply_topic(cfg)
    if not reply:
        return
    since = int(state.get("since") or time.time() - 120)
    started = int(time.time())
    try:
        with urllib.request.urlopen(reply + "/json?poll=1&since=%d" % since, timeout=15) as f:
            lines = f.read().decode("utf-8", "replace").splitlines()
    except Exception:
        return
    state["since"] = started - 5
    byfp = {r.get("fp"): r for r in records() if r.get("fp") and r.get("status") == "proposed"}
    for line in lines:
        try:
            parts = (json.loads(line).get("message") or "").split(":")
        except Exception:
            continue
        if len(parts) < 2 or parts[0] not in ("apply", "dismiss") or parts[1] not in byfp:
            continue
        r, who = byfp.pop(parts[1]), (parts[2] if len(parts) > 2 else "lock screen")[:60]
        if parts[0] == "apply":
            apply(cfg, r, who, False)
        else:
            r.update(status="dismissed", who=who)
            put(r)


def reap(cfg):
    """Runs that ended without reporting back (stopped, killed, server restarted)."""
    for r in records():
        st = r.get("status")
        rid = r.get("run") if st == "running" else r.get("applyRun") if st == "applying" else None
        if not rid or run_alive(rid) or time.time() - r.get("updated", 0) < 30:
            continue
        code = exit_code(rid)
        if code is None:
            r["status"], r["note"] = "failed", "The run stopped without an answer."
            put(r)
        else:
            finish(cfg, r, code, "apply" if st == "applying" else "start")


def tick(cfg):
    state = load(STATE, {})
    opened = state.setdefault("open", {})
    replies(cfg, state)
    reap(cfg)
    poll_ci(cfg, state)
    found = triggers(cfg, state)
    for key in list(opened):
        if key.startswith("ci:"):
            # A failed CI run is an event, not a state: it stays known for a week so it never starts twice.
            if time.time() - opened[key] > 7 * 86400:
                del opened[key]
            continue
        if key not in found:
            del opened[key]
            for r in records():
                if r.get("key") == key and r.get("status") == "proposed":
                    r["status"] = "resolved"
                    put(r)
    order = {"service": 0, "uptime": 1, "ci": 2, "disk": 3}
    new = sorted((k for k in found if k not in opened), key=lambda k: (order.get(found[k]["kind"], 9), k))
    busy = any(r.get("status") in OPEN and run_alive(r.get("run") if r.get("status") == "running" else r.get("applyRun") or "") for r in records())
    if new and not busy:
        key, t = new[0], found[new[0]]
        opened[key] = int(time.time())
        today = [r for r in records() if r.get("status") != "limited" and time.time() - r.get("started", 0) < 86400]
        if len(today) >= int(cfg.get("maxPerDay") or 3):
            r = dict(t, id=new_id(), key=key, started=int(time.time()), status="limited")
            put(r)
            push(cfg, r, "Not looked into: " + t["title"], "The daily limit of %d automatic investigations is reached." % int(cfg.get("maxPerDay") or 3), "hourglass")
        else:
            start(cfg, key, t)
        state.get("ciPending", {}).pop(key, None)
    old = records()[:-KEEP]
    for r in old:
        for suffix in (".json", ".start.prompt", ".apply.prompt"):
            try:
                os.remove(os.path.join(D, r["id"] + suffix))
            except OSError:
                pass
    save(STATE, state)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    cfg = load(CONFIG, None)
    if not cfg:
        return 0
    with Lock():
        if mode == "tick":
            tick(cfg)
        elif mode in ("finish", "apply", "dismiss") and len(sys.argv) > 2:
            r = record(sys.argv[2])
            if not r:
                print("@@missing")
                return 1
            if mode == "finish":
                finish(cfg, r, int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].lstrip("-").isdigit() else 1,
                       sys.argv[4] if len(sys.argv) > 4 else "start")
            elif mode == "apply":
                print(apply(cfg, r, (sys.argv[3] if len(sys.argv) > 3 else "app")[:60], len(sys.argv) > 4 and sys.argv[4] == "app"))
            elif r.get("status") == "proposed":
                r.update(status="dismissed", who=(sys.argv[3] if len(sys.argv) > 3 else "app")[:60])
                put(r)
                print("@@ok")
            else:
                print("@@state " + str(r.get("status")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
"""#
    }

    /// Starts one agent run detached (`RID`, `IID` and the prompt file `PF` come from the checker) and reports back
    /// when it ends. The investigation is read-only; the approved fix runs with full access, still under the house rules.
    static func launcher(_ c: Config, access: CLIAccess) -> String {
        let run = DetachedRun(id: "${RID}")
        let cli = LimitAwareRun.command(c.cli, prompt: "@@PROMPT@@", workingDirectory: "@@DIR@@", sessionID: nil, access: access, options: c.options, run: run)
            .replacingOccurrences(of: ShellQuote.quote("@@PROMPT@@"), with: "\"$(cat \"$PF\")\"")
            .replacingOccurrences(of: ShellQuote.quote("@@DIR@@"), with: "\"${DIR:-$HOME}\"")
        let kind = access == .readOnly ? "start" : "apply"
        let command = cli + "\nc=$?; python3 \"$HOME/.deckhand/investigate/inv.py\" finish \"$IID\" \"$c\" \(kind) >/dev/null 2>&1; (exit $c)"
        return """
        #!/bin/bash
        # Deckhand: one agent run for an investigation. Managed by the Deckhand app.
        export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
        export RID IID PF DIR
        mkdir -p ~/.deckhand/runs; chmod 700 ~/.deckhand ~/.deckhand/runs
        \(run.startCommand(command))
        """
    }

    /// Writes the checker, the two launchers and the settings, and adds the cron line (replacing an older one).
    public static func installCommand(_ c: Config) -> String {
        """
        D=\(directory); mkdir -p $D && chmod 700 ~/.deckhand $D
        printf '%s\\n' \(ShellQuote.quote(script)) > $D/inv.py
        printf '%s\\n' \(ShellQuote.quote(launcher(c, access: .readOnly))) > $D/start.sh
        printf '%s\\n' \(ShellQuote.quote(launcher(c, access: .full))) > $D/apply.sh
        printf '%s\\n' \(ShellQuote.quote(c.json)) > $D/config.json
        chmod 700 $D/inv.py $D/start.sh $D/apply.sh; chmod 600 $D/config.json
        command -v python3 >/dev/null 2>&1 || { echo '@@nopython'; exit 0; }
        command -v crontab >/dev/null 2>&1 || { echo '@@nocron'; exit 0; }
        T=$(crontab -l 2>/dev/null | grep -v -- ' \(cronTag)$')
        { [ -n "$T" ] && printf '%s\\n' "$T"; echo "* * * * * python3 $HOME/.deckhand/investigate/inv.py tick >/dev/null 2>&1 \(cronTag)"; } | crontab - && echo '@@ok'
        """
    }

    /// Removes the cron line and the checker. Earlier runs stay under Background tasks.
    public static let uninstallCommand = """
        T=$(crontab -l 2>/dev/null | grep -v -- ' \(cronTag)$')
        if [ -n "$T" ]; then printf '%s\\n' "$T" | crontab -; else crontab -r 2>/dev/null; fi
        rm -rf \(directory); echo '@@ok'
        """

    public static let statusCommand = """
        D=\(directory)
        command -v python3 >/dev/null 2>&1 || echo '@@nopython'
        crontab -l 2>/dev/null | grep -q -- ' \(cronTag)$' && echo '@@installed'
        [ -f $D/config.json ] && echo "@@config $(tr -d '\\n' < $D/config.json)"
        ls -t $D/i-*.json 2>/dev/null | head -n 50 | while IFS= read -r f; do echo "@@inv $(tr -d '\\n' < "$f")"; done
        true
        """

    /// Looks for problems right now instead of waiting for the next minute.
    public static let checkNowCommand = "python3 \(directory)/inv.py tick; echo '@@ok'"

    static func validID(_ id: String) -> Bool {
        id.range(of: #"^i-[0-9]{8}-[0-9]{6}(-[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// Applies the proposed fix, approved in the app (also for fixes that need Face ID). Prints `@@applying <run>`,
    /// `@@blocked <rule>` or `@@state <status>`.
    public static func applyCommand(id: String, device: String) -> String {
        guard validID(id) else { return "echo '@@failed bad id'" }
        return "python3 \(directory)/inv.py apply \(id) \(ShellQuote.quote(String(device.prefix(60)))) app"
    }

    public static func dismissCommand(id: String, device: String) -> String {
        guard validID(id) else { return "echo '@@failed bad id'" }
        return "python3 \(directory)/inv.py dismiss \(id) \(ShellQuote.quote(String(device.prefix(60))))"
    }

    public static func parse(_ output: String) -> Status {
        var s = Status()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        for line in output.split(separator: "\n").map(String.init) {
            if line == "@@installed" { s.installed = true }
            else if line == "@@nopython" { s.python = false }
            else if line.hasPrefix("@@config ") {
                s.config = try? dec.decode(Config.self, from: Data(line.dropFirst(9).utf8))
            } else if line.hasPrefix("@@inv "), let i = try? dec.decode(Investigation.self, from: Data(line.dropFirst(6).utf8)) {
                s.investigations.append(i)
            }
        }
        s.investigations.sort { $0.started > $1.started }
        return s
    }
}
