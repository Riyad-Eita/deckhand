import Foundation

/// The tmux and GNU screen sessions on a server: list them, open one in a terminal tab, start or end one.
public enum TerminalSessions {
    public enum Kind: String, Sendable, Hashable, Codable { case tmux, screen }

    public struct Session: Sendable, Hashable, Identifiable, Codable {
        public var kind: Kind
        /// tmux: the session name. screen: "pid.name", which is what screen needs to find it.
        public var name: String
        public var windows: Int?
        public var attached: Bool
        public var lastActivity: Date?
        public var id: String { "\(kind.rawValue):\(name)" }

        public init(kind: Kind, name: String, windows: Int? = nil, attached: Bool = false, lastActivity: Date? = nil) {
            self.kind = kind; self.name = name; self.windows = windows; self.attached = attached; self.lastActivity = lastActivity
        }

        /// The name without screen's pid prefix.
        public var shortName: String {
            guard kind == .screen, let dot = name.firstIndex(of: "."), name[..<dot].allSatisfy(\.isNumber) else { return name }
            return String(name[name.index(after: dot)...])
        }

        /// One of the sessions the app's terminal tabs keep ("deckhand", "deckhand-2", …).
        public var isDeckhandTab: Bool {
            let n = shortName
            return n == PersistentSession.name || (n.hasPrefix(PersistentSession.name + "-") && Int(n.dropFirst(PersistentSession.name.count + 1)) != nil)
        }
    }

    /// Finds tmux in ~/.local/bin too (installed there without root).
    public static let path = #"PATH="$HOME/.local/bin:$PATH""#

    /// tmux lines "T<TAB>name<TAB>windows<TAB>attached<TAB>activity", screen lines "S<TAB>pid.name<TAB>(Attached|Detached)".
    public static let listCommand = path + "; tmux ls -F 'T\t#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}' 2>/dev/null; "
        + #"screen -ls 2>/dev/null | awk -F'\t' '/^\t[0-9]+\./ { s = $3; gsub(/[()]/, "", s); print "S\t" $2 "\t" s }'; "#
        + #"command -v tmux >/dev/null 2>&1 && echo HAS_TMUX; command -v screen >/dev/null 2>&1 && echo HAS_SCREEN; true"#

    public struct Listing: Sendable, Hashable {
        public var sessions: [Session] = []
        public var hasTmux = false
        public var hasScreen = false
    }

    public static func parse(_ output: String) -> Listing {
        var l = Listing()
        for line in output.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "T" where f.count >= 5:
                l.sessions.append(Session(kind: .tmux, name: f[1], windows: Int(f[2]), attached: (Int(f[3]) ?? 0) > 0,
                                          lastActivity: Double(f[4]).map { Date(timeIntervalSince1970: $0) }))
            case "S" where f.count >= 3:
                l.sessions.append(Session(kind: .screen, name: f[1], attached: f[2].lowercased().hasPrefix("attached")))
            case "HAS_TMUX": l.hasTmux = true
            case "HAS_SCREEN": l.hasScreen = true
            default: break
            }
        }
        // Most recently used first; screen has no time, it goes last.
        l.sessions.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        return l
    }

    /// Typed into a fresh login shell of a terminal tab: replaces it with the session (shared with other clients).
    public static func attachCommand(_ s: Session) -> String {
        switch s.kind {
        case .tmux: "\(path); exec tmux attach-session -t \(ShellQuote.quote("=" + s.name))"
        case .screen: "exec screen -x \(ShellQuote.quote(s.name))"
        }
    }

    /// Ends a session for good (asks first in the app).
    public static func killCommand(_ s: Session) -> String {
        switch s.kind {
        case .tmux: "\(path); tmux kill-session -t \(ShellQuote.quote("=" + s.name))"
        case .screen: "screen -S \(ShellQuote.quote(s.name)) -X quit"
        }
    }

    /// A new tmux session (detached), to open in a tab afterwards.
    public static func newCommand(name: String) -> String {
        "\(path); tmux new-session -d -s \(ShellQuote.quote(clean(name)))"
    }

    /// tmux session names can't hold '.' or ':'.
    public static func clean(_ name: String) -> String {
        let s = name.trimmingCharacters(in: .whitespaces).map { ".:".contains($0) ? "-" : $0 }
        return s.isEmpty ? "work" : String(s.prefix(40))
    }
}

/// tmux where it is missing: the package manager with root, else built from the official sources into ~/.local.
public enum TmuxInstall {
    public struct Source: Sendable, Hashable {
        public var name: String
        public var url: String
        public var sha256: String
    }

    /// Pinned releases; each download is checked against its SHA-256 before it is unpacked.
    public static let sources = [
        Source(name: "libevent-2.1.13-stable", url: "https://github.com/libevent/libevent/releases/download/release-2.1.13-stable/libevent-2.1.13-stable.tar.gz",
               sha256: "f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c"),
        Source(name: "ncurses-6.5", url: "https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz",
               sha256: "136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6"),
        Source(name: "byacc-20260126", url: "https://invisible-island.net/archives/byacc/byacc-20260126.tgz",
               sha256: "b618c5fb44c2f5f048843db90f7d1b24f78f47b07913c8c7ba8c942d3eb24b00"),
        Source(name: "tmux-3.8", url: "https://github.com/tmux/tmux/releases/download/3.8/tmux-3.8.tar.gz",
               sha256: "e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e"),
    ]

    /// With root (through the app's sudo runner): the distribution's package.
    public static let packageScript = """
    set -e
    if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
    elif command -v dnf >/dev/null 2>&1; then dnf install -y tmux
    elif command -v yum >/dev/null 2>&1; then yum install -y tmux
    elif command -v apk >/dev/null 2>&1; then apk add tmux
    elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm tmux
    elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install tmux
    else echo "@@nopkg"; exit 3; fi
    echo "@@ok"
    """

    /// Without root: builds libevent, ncurses and tmux into ~/.local (needs a C compiler and make). Prints
    /// "@@step <what>" while it works, "@@nocc" without a compiler, "@@ok" at the end.
    public static var buildScript: String {
        let fetch = sources.map { s in
            "fetch \(ShellQuote.quote(s.url)) \(ShellQuote.quote(s.name)) \(s.sha256)"
        }.joined(separator: "\n")
        return """
        set -e
        command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || { echo "@@nocc"; exit 3; }
        command -v make >/dev/null 2>&1 || { echo "@@nocc"; exit 3; }
        P="$HOME/.local"; W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; export PATH="$P/bin:$PATH"
        sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
        fetch() {
          echo "@@step download $2"
          if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$W/$2.tar.gz" "$1"; else wget -qO "$W/$2.tar.gz" "$1"; fi
          [ "$(sha "$W/$2.tar.gz")" = "$3" ] || { echo "@@badsum $2"; exit 4; }
          tar -xzf "$W/$2.tar.gz" -C "$W"
        }
        \(fetch)
        J="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
        echo "@@step build libevent"
        (cd "$W/\(sources[0].name)" && ./configure --prefix="$P" --enable-shared=no --disable-openssl >/dev/null && make -j"$J" >/dev/null && make install >/dev/null)
        echo "@@step build ncurses"
        (cd "$W/\(sources[1].name)" && ./configure --prefix="$P" --with-shared=no --without-debug --without-ada --without-cxx-binding --enable-widec >/dev/null && make -j"$J" >/dev/null && make install >/dev/null)
        ln -sf libncursesw.a "$P/lib/libncurses.a"   # tmux's configure also links -lncurses
        if ! command -v yacc >/dev/null 2>&1 && ! command -v bison >/dev/null 2>&1; then
          echo "@@step build byacc"
          (cd "$W/\(sources[2].name)" && ./configure --prefix="$P" >/dev/null && make -j"$J" >/dev/null && make install >/dev/null)
        fi
        echo "@@step build tmux"
        (cd "$W/\(sources[3].name)" && PKG_CONFIG_PATH="$P/lib/pkgconfig" CPPFLAGS="-I$P/include -I$P/include/ncursesw" CFLAGS="-I$P/include -I$P/include/ncursesw" LDFLAGS="-L$P/lib" \\
          ./configure --prefix="$P" >/dev/null && make -j"$J" >/dev/null && make install >/dev/null)
        "$P/bin/tmux" -V
        echo "@@ok"
        """
    }
}
