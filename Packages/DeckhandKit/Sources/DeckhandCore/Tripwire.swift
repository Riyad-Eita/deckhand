import Foundation

/// Decoy files — fake cloud keys, a fake app secrets file, a fake backup, an old fake SSH key — in places an intruder
/// looks first. A small watcher (inotify, no extra packages) pushes the moment one is opened: who, which process, when.
/// The decoys hold nothing real and grant no access.
public enum Tripwire {
    static let watcher = "/usr/local/lib/deckhand/tripwire.py"
    static let unit = "/etc/systemd/system/deckhand-tripwire.service"
    static let config = "/etc/deckhand/tripwire.json"
    static let log = "/var/log/deckhand-tripwire.log"

    public struct Decoy: Sendable, Hashable, Codable, Identifiable {
        public var id: String { path }
        public var path: String
        public var title: String
        var content: String
        var owner: String?
    }

    static func random(_ n: Int, _ alphabet: String) -> String { String((0..<n).map { _ in alphabet.randomElement()! }) }

    /// The decoys for a server whose login user lives in `home`. Fresh random fakes every time.
    public static func decoys(home: String, user: String) -> [Decoy] {
        let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", mixed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let aws = """
        [default]
        aws_access_key_id = AKIA\(random(16, upper))
        aws_secret_access_key = \(random(40, mixed))
        region = eu-central-1
        """
        let env = """
        DATABASE_URL=postgres://app:\(random(20, mixed))@10.0.3.7:5432/production
        STRIPE_SECRET_KEY=sk_live_\(random(24, mixed))
        JWT_SECRET=\(random(48, mixed))
        """
        let backup = "-- PostgreSQL database dump\n-- Dumped from database version 16.4\nSET statement_timeout = 0;\n"
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + (0..<6).map { _ in random(70, mixed) }.joined(separator: "\n") + "\n-----END OPENSSH PRIVATE KEY-----"
        return [
            Decoy(path: "/root/.aws/credentials", title: String(localized: "Cloud keys (root)"), content: aws, owner: nil),
            Decoy(path: "\(home)/.env.production", title: String(localized: "App secrets"), content: env, owner: user),
            Decoy(path: "\(home)/backups/db-full-latest.sql", title: String(localized: "Database backup"), content: backup, owner: user),
            Decoy(path: "\(home)/.ssh/id_rsa_old", title: String(localized: "Old SSH key"), content: key, owner: user),
        ]
    }

    /// The watcher: one inotify watch per decoy, the reading process from /proc, a push (debounced) and a log line.
    static let watcherScript = #"""
    #!/usr/bin/env python3
    # Deckhand tripwires: pushes when a decoy file is opened. Managed by the Deckhand app.
    # fanotify names the process with every event; without it (containers) inotify still notices the open.
    import ctypes, ctypes.util, json, os, pwd, socket, struct, time, urllib.request
    CONF = os.environ.get("TRIPWIRE_CONF", "/etc/deckhand/tripwire.json"); LOG = os.environ.get("TRIPWIRE_LOG", "/var/log/deckhand-tripwire.log")
    conf = json.load(open(CONF))
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    libc.fanotify_mark.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_uint64, ctypes.c_int, ctypes.c_char_p]
    by_path = {d["path"]: d for d in conf["decoys"]}
    last = {}

    def proc(pid):
        try:
            uid = int([l for l in open("/proc/%d/status" % pid) if l.startswith("Uid:")][0].split()[1])
            cmd = open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode(errors="replace").strip()
            return pwd.getpwuid(uid).pw_name, cmd[:200] or open("/proc/%d/comm" % pid).read().strip()
        except Exception:
            return "unknown", "(already exited)"

    def scan(path):
        for p in os.listdir("/proc"):
            if not p.isdigit() or int(p) == os.getpid(): continue
            try:
                for f in os.listdir("/proc/%s/fd" % p):
                    if os.readlink("/proc/%s/fd/%s" % (p, f)) == path: return int(p)
            except Exception: continue
        return None

    def alert(d, pid):
        if time.time() - last.get(d["path"], 0) < 120: return
        last[d["path"]] = time.time()
        user, cmd = proc(pid) if pid else ("unknown", "(the process already closed it)")
        when = time.strftime("%Y-%m-%d %H:%M:%S %Z")
        with open(LOG, "a") as f: f.write("%s %s opened by %s (pid %s: %s)\n" % (when, d["path"], user, pid or "?", cmd))
        try:
            body = "%s was opened on %s by %s.\n%s (pid %s)\n%s" % (d["title"], socket.gethostname(), user, cmd, pid or "?", when)
            req = urllib.request.Request(conf["topic"], data=body.encode(), method="POST",
                headers={"Title": "Tripwire on %s" % socket.gethostname(), "Priority": "urgent", "Tags": "rotating_light"})
            urllib.request.urlopen(req, timeout=10).read()
        except Exception: pass

    # fanotify: FAN_CLASS_NOTIF, events FAN_OPEN|FAN_ACCESS, event fd opened read-only.
    fan = libc.fanotify_init(0, os.O_RDONLY | getattr(os, "O_LARGEFILE", 0))
    if fan >= 0:
        for path in by_path:
            libc.fanotify_mark(fan, 1, 0x20 | 0x01, -100, path.encode())
        meta = struct.Struct("IBBHQii")
        while True:
            buf = os.read(fan, 4096); i = 0
            while i + meta.size <= len(buf):
                ev_len, ver, _, mlen, mask, fd, pid = meta.unpack_from(buf, i); i += ev_len or meta.size
                if fd < 0: continue
                try: path = os.readlink("/proc/self/fd/%d" % fd)
                finally: os.close(fd)
                if pid != os.getpid() and path in by_path: alert(by_path[path], pid)
    else:
        fd = libc.inotify_init1(0)
        watches = {}
        for path, d in by_path.items():
            wd = libc.inotify_add_watch(fd, path.encode(), 0x20 | 0x01)
            if wd >= 0: watches[wd] = d
        while True:
            buf = os.read(fd, 4096); i = 0
            while i < len(buf):
                wd, mask, cookie, n = struct.unpack_from("iIII", buf, i); i += 16 + n
                d = watches.get(wd)
                if d: alert(d, scan(d["path"]))
    """#

    static let unitFile = """
    [Unit]
    Description=Deckhand tripwires
    After=network-online.target

    [Service]
    ExecStart=/usr/bin/python3 \(watcher)
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    """

    static let reload = """
    systemctl daemon-reload
    if [ -f \(unit) ]; then systemctl enable deckhand-tripwire >/dev/null 2>&1; systemctl restart deckhand-tripwire; else systemctl stop deckhand-tripwire 2>/dev/null; true; fi
    """

    /// Plants the decoys and starts the watcher. Undoing it removes everything again.
    public static func enable(topicURL: String, decoys: [Decoy]) -> ConfigChange? {
        guard topicURL.hasPrefix("https://") || topicURL.hasPrefix("http://"), !decoys.isEmpty else { return nil }
        struct Conf: Encodable { let topic: String; let decoys: [[String: String]] }
        let conf = Conf(topic: topicURL, decoys: decoys.map { ["path": $0.path, "title": $0.title] })
        let json = String(decoding: (try? JSONEncoder().encode(conf)) ?? Data(), as: UTF8.self)
        let plant = decoys.map { d in
            let q = ShellQuote.quote(d.path)
            let own = d.owner.map { "chown \(ShellQuote.quote($0)): \(q) 2>/dev/null || true" } ?? ""
            return """
            mkdir -p "$(dirname \(q))"
            printf '%s\\n' \(ShellQuote.quote(d.content)) > \(q) && chmod 600 \(q)
            \(own)
            """
        }.joined(separator: "\n")
        return ConfigChange(
            title: "Plant tripwires", files: decoys.map(\.path) + [watcher, unit, config],
            apply: """
            command -v python3 >/dev/null 2>&1 || { echo 'python3 is missing'; exit 1; }
            mkdir -p /usr/local/lib/deckhand /etc/deckhand
            \(plant)
            printf '%s\\n' \(ShellQuote.quote(watcherScript)) > \(watcher) && chmod 700 \(watcher)
            printf '%s\\n' \(ShellQuote.quote(unitFile)) > \(unit)
            printf '%s\\n' \(ShellQuote.quote(json)) > \(config) && chmod 600 \(config)
            """,
            reload: reload, verify: "sleep 1; systemctl is-active --quiet deckhand-tripwire")
    }

    /// Removes the decoys and the watcher.
    public static func disable(decoys: [String]) -> ConfigChange {
        ConfigChange(
            title: "Remove tripwires", files: decoys + [watcher, unit, config],
            apply: "systemctl disable --now deckhand-tripwire 2>/dev/null || true\nrm -f \((decoys + [watcher, unit, config]).map(ShellQuote.quote).joined(separator: " "))",
            reload: reload)
    }

    /// Root script: on or off, the decoys, and the last alerts.
    public static let statusScript = """
    systemctl is-active --quiet deckhand-tripwire 2>/dev/null && echo '@@active'
    [ -f \(config) ] && python3 -c 'import json; [print("@@decoy", d["path"], "\\t" + d["title"]) for d in json.load(open("\(config)"))["decoys"]]' 2>/dev/null
    [ -f \(log) ] && tail -n 20 \(log) | sed 's/^/@@hit /'
    true
    """

    public struct Status: Sendable, Hashable {
        public var active = false
        public var decoys: [(path: String, title: String)] = []
        public var hits: [String] = []
        public static func == (a: Status, b: Status) -> Bool { a.active == b.active && a.hits == b.hits && a.decoys.map(\.path) == b.decoys.map(\.path) }
        public func hash(into h: inout Hasher) { h.combine(active); h.combine(hits) }
    }

    public static func parse(_ out: String) -> Status {
        var s = Status()
        for line in out.split(separator: "\n").map(String.init) {
            if line == "@@active" { s.active = true }
            else if line.hasPrefix("@@decoy ") {
                let p = line.dropFirst(8).components(separatedBy: " \t")
                s.decoys.append((p[0], p.count > 1 ? p[1] : ""))
            } else if line.hasPrefix("@@hit ") { s.hits.append(String(line.dropFirst(6))) }
        }
        s.hits.reverse()
        return s
    }
}
