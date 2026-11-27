import Foundation

/// Lets a detached Codex / Claude Code run use `sudo` although nobody can type a password into it.
///
/// Before the run starts, the app sends the sudo password over stdin (never in a command line) into
/// `~/.deckhand/runs/<id>.sudo/` (mode 700). That folder also gets an askpass helper and a `sudo` wrapper
/// that goes first on the run's PATH: it drops `-n` / `-S` and adds `-A`, so `sudo -n systemctl restart x`
/// works as well as plain `sudo …`. The folder is removed when the run ends or is stopped.
public enum RunSudo {
    public static func folder(_ run: DetachedRun) -> String { run.base + ".sudo" }

    /// Run through a channel; reads the password from the first stdin line, writes the helpers, checks the
    /// password with a fresh `sudo -k` and prints `@@sudo ok` or `@@sudo wrong` (the folder is removed then).
    public static func prepareCommand(_ run: DetachedRun) -> String {
        let d = folder(run)
        return """
        umask 077; mkdir -p ~/.deckhand/runs; chmod 700 ~/.deckhand ~/.deckhand/runs
        D=\(d); rm -rf "$D"; mkdir -p "$D"; chmod 700 "$D"
        IFS= read -r P; printf '%s\\n' "$P" > "$D/pw"; P=
        R=$(command -v sudo); [ -n "$R" ] || { rm -rf "$D"; echo '@@sudo missing'; exit 0; }
        printf '#!/bin/sh\\nexec cat %s\\n' "$D/pw" > "$D/askpass"
        printf '%s\\n' \(ShellQuote.quote(wrapper)) | sed "s|@@REAL@@|$R|; s|@@ASKPASS@@|$D/askpass|" > "$D/sudo"
        chmod 700 "$D/askpass" "$D/sudo"
        if SUDO_ASKPASS="$D/askpass" "$R" -A -k true </dev/null >/dev/null 2>&1; then echo '@@sudo ok'; else rm -rf "$D"; echo '@@sudo wrong'; fi
        """
    }

    /// The `sudo` on the run's PATH. Leaves every option alone except the ones that would make sudo fail
    /// without a terminal (`-n`, `-S`), up to the command itself.
    static let wrapper = #"""
    #!/bin/sh
    # Deckhand: sudo for this run, answered by the askpass helper next to it. Removed when the run ends.
    opts=1; skip=0
    for a do
      shift
      if [ "$opts" = 1 ]; then
        if [ "$skip" = 1 ]; then skip=0
        else
          case "$a" in
            -n|-S|--non-interactive|--stdin) continue ;;
            -u|-g|-C|-D|-h|-p|-r|-t|-U|-T|-R) skip=1 ;;
            --) opts=0 ;;
            -*) ;;
            *) opts=0 ;;
          esac
        fi
      fi
      set -- "$@" "$a"
    done
    SUDO_ASKPASS='@@ASKPASS@@' exec '@@REAL@@' -A "$@"
    """#

    /// Wraps a run's command: the wrapper first on PATH, SUDO_ASKPASS set, the folder removed afterwards.
    public static func wrap(_ command: String, run: DetachedRun) -> String {
        let d = folder(run)
        return """
        trap 'rm -rf \(d)' EXIT; trap 'exit 143' TERM INT
        export PATH=\(d):"$PATH" SUDO_ASKPASS=\(d)/askpass
        \(command)
        """
    }

    /// Outcome of `prepareCommand`.
    public enum Prepared: Equatable, Sendable { case ok, wrongPassword, noSudo }

    public static func parse(_ output: String) -> Prepared {
        if output.contains("@@sudo ok") { return .ok }
        if output.contains("@@sudo missing") { return .noSudo }
        return .wrongPassword
    }

    /// Stores the password for `run` and checks it. Nothing is written when it is wrong.
    public static func prepare(_ run: DetachedRun, password: String, on shell: any ChannelShell) async throws -> Prepared {
        let channel = try await shell.openChannel(prepareCommand(run) + " 2>&1")
        defer { channel.close() }
        try await channel.send(password)
        var out = ""
        for try await line in channel.lines {
            out += line + "\n"
            if line.hasPrefix("@@sudo") { break }
        }
        return parse(out)
    }
}
