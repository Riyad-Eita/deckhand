import Foundation

extension HouseRules {
    /// The checker that runs on the server: a PreToolUse hook for Claude Code and Codex, and the check the own-key
    /// agent asks before each tool call. One script, so every engine obeys the same rules.
    /// Also wires itself into the CLIs (`install` / `uninstall`).
    static let hookScript = #"""
#!/usr/bin/env python3
# Deckhand house rules. Checks a tool call before an agent runs it; managed by the Deckhand app.
#   hook.py claude|codex   PreToolUse hook: exit 2 + reason on stderr blocks the call
#   hook.py deckhand       prints a JSON verdict (the app's own agent)
#   hook.py install|uninstall
import hashlib, json, os, re, shlex, shutil, sys, time

DIR = os.path.expanduser("~/.deckhand/rules")
RULES = os.path.join(DIR, "rules.json")
ALLOW = os.path.join(DIR, "allow")
HOOK = os.path.join(DIR, "hook.py")
MARK = ".deckhand/rules/hook.py"
SEG = r"[^;&|\n]*"

RESTART = re.compile(
    r"\b(systemctl|service)\b" + SEG + r"\b(restart|stop|start|reload|kill|try-restart|reload-or-restart|isolate)\b"
    r"|\b(reboot|shutdown|poweroff|halt)\b"
    r"|\bdocker(\s+compose|-compose)?\b" + SEG + r"\b(restart|stop|kill|down|up)\b"
    r"|\bpm2\s+(restart|stop|reload|delete)\b|\bnginx\s+-s\s+(reload|stop|quit)\b"
    r"|\bsupervisorctl\s+(restart|stop)\b|\b(kill|pkill|killall)\b")
OPEN_PORT = re.compile(
    r"\bufw\b" + SEG + r"\ballow\b"
    r"|\bip6?tables\b" + SEG + r"(\s-A|\s-I|--append|--insert)\b" + SEG + r"\bACCEPT\b"
    r"|\bfirewall-cmd\b" + SEG + r"--add-(port|service)"
    r"|\bnft\b" + SEG + r"\badd\b" + SEG + r"\baccept\b"
    r"|\bdocker\s+(container\s+)?(run|create)\b" + SEG + r"\s(-p|--publish|-P|--publish-all)\b")
SAFE = re.compile(
    r"^(sudo\s+)?("
    r"(ls|cat|head|tail|less|more|grep|egrep|fgrep|wc|stat|file|du|df|free|uptime|uname|whoami|id|pwd|echo|printf"
    r"|printenv|which|type|ps|pgrep|ss|netstat|lsof|cut|tr|jq|diff|cmp|md5sum|sha256sum|realpath|readlink"
    r"|basename|dirname|test|true|false|cd|nproc|lscpu|lsblk|findmnt|getent|last|lastlog|w|who|column|nl|base64"
    r"|hexdump|strings|tac|zcat|zgrep)(\s.*)?"
    r"|hostname(\s+-\S+)*"
    r"|date(?!.*\s(-s|--set))(\s.*)?"
    r"|sort(?!.*\s(-o|--output))(\s.*)?"
    r"|tree(?!.*\s-o)(\s.*)?"
    r"|rg(?!.*--pre)(\s.*)?"
    r"|dmesg(?!.*\s(-c|-C|--clear|--read-clear))(\s.*)?"
    r"|journalctl(?!.*--(vacuum|rotate|flush|relinquish))(\s.*)?"
    r"|sed(?!.*\s(-i|--in-place))(\s.*)?"
    r"|find(?!.*\s-(delete|exec|execdir|ok|okdir|fprint|fprintf|fls)\b)(\s.*)?"
    r"|ip\s+(-\S+\s+)*(a|addr|address|r|route|link|neigh)(\s+(show|list|ls)\b.*)?"
    r"|git(?!.*--output)\s+(status|log|diff|show|branch|remote|rev-parse|ls-files|blame|grep|describe|config\s+--get)\b.*"
    r"|systemctl\s+(--\S+\s+)*(status|is-active|is-enabled|is-failed|list-units|list-unit-files|list-timers|show|cat)\b.*"
    r"|docker\s+(ps|logs|inspect|images|version|info|stats\s+--no-stream|compose\s+(ps|logs|config))\b.*"
    r"|curl(?!.*\s(-o|-O|--output|-X|--request|-d|--data\S*|-F|--form|-T|--upload-file)\b)(\s.*)?"
    r"|top\s+-b.*|crontab\s+-l"
    r")$")
DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def load_rules():
    try:
        with open(RULES) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def norm(path, cwd):
    path = os.path.expanduser(path.strip())
    if not os.path.isabs(path):
        path = os.path.join(os.path.expanduser(cwd or "~"), path)
    return os.path.realpath(os.path.normpath(path))


def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def patch_paths(patch):
    return [m.group(2).strip() for m in re.finditer(r"^\*\*\* (Add File|Update File|Delete File|Move to): (.+)$", patch, re.M)]


def action(engine, data):
    """(command, paths written, cwd) for one tool call."""
    tool = data.get("tool_name") or ""
    inp = data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()
    command = inp.get("command") if isinstance(inp, dict) else None
    if isinstance(command, list):
        command = " ".join(str(c) for c in command)
    if tool in ("Bash", "shell", "exec_command", "local_shell", "unified_exec", "run_command"):
        return command or "", [], cwd
    if tool == "apply_patch":
        return None, patch_paths(command or inp.get("input", "") or "") or ["(patch)"], cwd
    for key in ("file_path", "notebook_path", "path"):
        if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit", "write_file", "edit_file") and inp.get(key):
            return None, [inp[key]], cwd
    return None, [], cwd


def read_only_ok(command):
    c = re.sub(r"\d*>&\d+|\d*>>?\s*/dev/null", " ", command)
    if re.search(r">|`|\$\(|<\(", c):
        return False
    return all(SAFE.search(s.strip()) for s in re.split(r"[;&|\n]+", c) if s.strip())


def mentions(command, path):
    home = os.path.expanduser("~")
    variants = {path.rstrip("/") or "/"}
    if path.startswith("~/"):
        rest = path[2:].rstrip("/")
        variants |= {home + "/" + rest, "$HOME/" + rest, "${HOME}/" + rest}
    elif path.startswith(home + "/"):
        rest = path[len(home) + 1:].rstrip("/")
        variants |= {"~/" + rest, "$HOME/" + rest, "${HOME}/" + rest}
    for v in variants:
        if re.search(r"(?<![\w.-])" + re.escape(v) + r"(?=$|[\s'\"/;&|)*}])", command):
            return True
    return False


def in_window(q, now):
    tz = q.get("timeZone")
    t = None
    if tz:
        try:
            from datetime import datetime
            from zoneinfo import ZoneInfo
            t = datetime.fromtimestamp(now, ZoneInfo(tz)).timetuple()
        except Exception:
            t = None
    t = t or time.localtime(now)
    start = int(q["start"][:2]) * 60 + int(q["start"][3:5])
    end = int(q["end"][:2]) * 60 + int(q["end"][3:5])
    m = t.tm_hour * 60 + t.tm_min
    day = t.tm_wday + 1
    days = q.get("days") or [1, 2, 3, 4, 5, 6, 7]
    if start < end:
        return start <= m < end and day in days
    if m >= start:
        return day in days
    return m < end and ((day + 5) % 7 + 1) in days


def days_label(days):
    days = sorted(days or [1, 2, 3, 4, 5, 6, 7])
    if days == [1, 2, 3, 4, 5]:
        return "Mon-Fri"
    if len(days) == 7:
        return "every day"
    return ", ".join(DAYS[d - 1] for d in days)


def check(rules, engine, data, now):
    """(rule id, title, subject) of the first rule the call breaks, or None."""
    command, paths, cwd = action(engine, data)
    if command is None and not paths:
        return None
    if rules.get("readOnly"):
        if paths:
            return "readOnly", "Read-only mode: agents may look, not change", paths[0]
        if not read_only_ok(command):
            return "readOnly", "Read-only mode: agents may look, not change", command
    for i, p in enumerate(rules.get("protectedPaths") or []):
        root = norm(p, cwd)
        for target in paths:
            if inside(norm(target, cwd), root):
                return "path:%d" % i, "Hands off %s" % p, target
        if command is not None and (mentions(command, p) or inside(norm(cwd, cwd), root)):
            return "path:%d" % i, "Hands off %s" % p, command
    if command is not None:
        for i, c in enumerate(rules.get("forbiddenCommands") or []):
            words = c.split()
            if words and re.search(r"(?<![\w./-])" + r"\s+".join(re.escape(w) for w in words) + r"(?![\w-])", command):
                return "command:%d" % i, "Never run `%s`" % c, command
        if rules.get("noOpenPorts") and OPEN_PORT.search(command):
            return "noOpenPorts", "Never open ports", command
        q = rules.get("quietHours")
        if q and RESTART.search(command) and in_window(q, now):
            return "quietHours", "No restarts %s-%s (%s)" % (q["start"], q["end"], days_label(q.get("days"))), command
    return None


def allowed_once(fp, now):
    try:
        with open(ALLOW) as f:
            lines = [l.split() for l in f if l.strip()]
    except FileNotFoundError:
        return False
    keep = [l for l in lines if len(l) == 2 and float(l[1]) > now]
    hit = any(l[0] == fp for l in keep)
    keep = [l for l in keep if l[0] != fp]
    with open(ALLOW, "w") as f:
        f.writelines("%s %s\n" % (a, b) for a, b in keep)
    return hit


def write_json(path, data):
    tmp = path + ".dh"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def wire_claude(on):
    if not (shutil.which("claude") or os.path.isdir(os.path.expanduser("~/.claude"))):
        return False
    path = os.path.expanduser("~/.claude/settings.json")
    data = {}
    if os.path.exists(path):
        with open(path) as f:
            text = f.read()
        data = json.loads(text) if text.strip() else {}
    hooks = data.get("hooks") or {}
    groups = [g for g in hooks.get("PreToolUse") or [] if not any(MARK in (h.get("command") or "") for h in g.get("hooks") or [])]
    if on:
        groups.append({"matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit",
                       "hooks": [{"type": "command", "command": 'python3 "$HOME/.deckhand/rules/hook.py" claude'}]})
    if groups:
        hooks["PreToolUse"] = groups
    else:
        hooks.pop("PreToolUse", None)
    if hooks:
        data["hooks"] = hooks
    else:
        data.pop("hooks", None)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_json(path, data)
    return True


def wire_codex(on):
    home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    if not (shutil.which("codex") or os.path.isdir(home)):
        return False
    os.makedirs(home, exist_ok=True)
    path = os.path.join(home, "hooks.json")
    data = {}
    if os.path.exists(path):
        with open(path) as f:
            text = f.read()
        data = json.loads(text) if text.strip() else {}
    hooks = data.get("hooks") or {}
    groups = [g for g in hooks.get("PreToolUse") or [] if not any(MARK in (h.get("command") or "") for h in g.get("hooks") or [])]
    command = "python3 %s codex" % shlex.quote(HOOK)
    if on:
        groups.append({"hooks": [{"type": "command", "command": command}]})
    if groups:
        hooks["PreToolUse"] = groups
    else:
        hooks.pop("PreToolUse", None)
    data["hooks"] = hooks
    if hooks or len(data) > 1:
        write_json(path, data)
    elif os.path.exists(path):
        os.remove(path)
    # Codex only runs hooks the user trusted: record the hash it expects for exactly this declaration.
    config = os.path.join(home, "config.toml")
    text = open(config).read() if os.path.exists(config) else ""
    text = re.sub(r"\n?# deckhand:rules\n.*?# /deckhand:rules\n", "\n", text, flags=re.S).rstrip("\n")
    if on:
        identity = {"event_name": "pre_tool_use", "hooks": [{"async": False, "command": command, "timeout": 600, "type": "command"}]}
        digest = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        key = "%s:pre_tool_use:%d:0" % (path, len(groups) - 1)
        text += "\n\n# deckhand:rules\n[hooks.state.%s]\ntrusted_hash = \"sha256:%s\"\n# /deckhand:rules\n" % (json.dumps(key), digest)
    with open(config + ".dh", "w") as f:
        f.write(text.lstrip("\n") + ("" if text.endswith("\n") or not text else "\n"))
    os.replace(config + ".dh", config)
    return True


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode in ("install", "uninstall"):
        on = mode == "install"
        for name, wire in (("claude", wire_claude), ("codex", wire_codex)):
            try:
                if wire(on):
                    print("@@" + name)
            except Exception as e:
                print("@@error %s: %s" % (name, e))
        print("@@ok")
        return 0
    try:
        rules = load_rules()
    except Exception:
        rules = {"readOnly": True}
        print("The house rules file is damaged; everything that changes the server is blocked until it is saved again in Deckhand.", file=sys.stderr)
    if not rules:
        return 0
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    now = time.time()
    hit = check(rules, mode, data, now)
    if mode == "deckhand":
        print(json.dumps({"blocked": False} if not hit else {"blocked": True, "rule": hit[0], "title": hit[1]}))
        return 0
    if not hit:
        return 0
    rid, title, subject = hit
    fp = hashlib.sha256((rid + "\n" + subject).encode()).hexdigest()[:12]
    if allowed_once(fp, now):
        return 0
    print("Blocked by house rule: %s. The server owner set this rule in Deckhand; don't try to get around it. "
          "Tell the user what you wanted to do: they can allow it once in the app. [deckhand-rule %s %s]" % (title, rid, fp), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
"""#
}
