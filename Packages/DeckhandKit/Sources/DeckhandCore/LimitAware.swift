import Foundation

/// Wraps a server CLI turn so that hitting a usage limit doesn't end the task: the run waits on the server
/// until the limit resets and then continues the same session. Runs fully on the server — the phone can be off.
public enum LimitAwareRun {
    /// How often one task may be resumed after a limit (guards against loops when the reset time can't be read).
    public static let maxResumes = 12
    public static let continuePrompt = "You were paused by a usage limit, which has now reset. Continue the task where you left off."

    public static func command(
        _ cli: ServerCLI, prompt: String, workingDirectory: String, sessionID: String?, access: CLIAccess,
        options: CLIOptions = .init(), run: DetachedRun
    ) -> String {
        let first = ServerCLIRun.command(cli, prompt: prompt, workingDirectory: workingDirectory, sessionID: sessionID, access: access, options: options)
        let resume = ServerCLIRun.command(cli, prompt: continuePrompt, workingDirectory: workingDirectory, sessionID: "@@SID@@", access: access, options: options)
            .replacingOccurrences(of: ShellQuote.quote("@@SID@@"), with: "\"$sid\"")
        let out = run.base + ".out"
        return """
        \(waitFunction)
        \(first)
        code=$?
        n=0
        while [ "$code" -ne 0 ] && [ "$n" -lt \(maxResumes) ]; do
          last=$(tail -n 3 \(out))
          printf '%s' "$last" | grep -E '"is_error":true|"type":"turn\\.failed"|"type":"error"' | grep -qiE 'limit' || break
          sid=$(grep -oE '"(session_id|thread_id)":"[^"]+"' \(out) | tail -n 1 | sed -E 's/.*"([^"]+)"$/\\1/')
          [ -n "$sid" ] || break
          secs=$(dh_wait "$last")
          until=$(( $(date +%s) + secs ))
          echo "$until" > \(run.base).waiting
          printf '{"type":"deckhand.waiting","until":%s}\\n' "$until"
          sleep "$secs"
          rm -f \(run.base).waiting
          echo '{"type":"deckhand.resumed"}'
          \(resume)
          code=$?
          n=$((n + 1))
        done
        (exit $code)
        """
    }

    /// `dh_wait "<text>"` prints how many seconds to wait for the limit named in the text to reset
    /// (plus a minute of slack). Understands "resets 2:50am (Europe/Berlin)", "resets Nov 12, 3pm (…)",
    /// "limit reached|<epoch>", "try again in 2 hours 5 minutes" and "try again at 3:15 PM"; 30 minutes otherwise.
    public static let waitFunction = #"""
    dh_wait() {
      t=$(printf '%s' "$1" | tr -d ','); now=$(date +%s); s=
      e=$(printf '%s' "$t" | grep -oE 'limit reached\|[0-9]{10}' | grep -oE '[0-9]{10}' | head -n 1)
      [ -n "$e" ] && s=$e
      if [ -z "$s" ]; then
        w=$(printf '%s' "$t" | grep -oiE 'resets (at )?[0-9A-Za-z: ]*[0-9](am|pm| am| pm)?' | tail -n 1 | sed -E 's/^[Rr]esets (at )?//')
        tz=$(printf '%s' "$t" | grep -oE '\([A-Za-z]+/[A-Za-z_]+(/[A-Za-z_]+)?\)' | tail -n 1 | tr -d '()')
        if [ -n "$w" ]; then
          if [ -n "$tz" ]; then s=$(TZ="$tz" date -d "$w" +%s 2>/dev/null); else s=$(date -d "$w" +%s 2>/dev/null); fi
        fi
      fi
      if [ -z "$s" ]; then
        w=$(printf '%s' "$t" | grep -oiE 'try again (in|at) [0-9A-Za-z: ]*[0-9A-Za-z]' | head -n 1)
        case "$w" in
          *" in "*) s=$(date -d "+${w#* in }" +%s 2>/dev/null) ;;
          *" at "*) s=$(date -d "${w#* at }" +%s 2>/dev/null) ;;
        esac
      fi
      if [ -z "$s" ]; then echo 1800; return; fi
      # An exact time already past means the limit has reset; only a time of day ("resets 3am") rolls to tomorrow.
      if [ -n "$e" ]; then [ "$s" -lt "$now" ] && s=$now
      else while [ "$s" -le "$now" ]; do s=$((s + 86400)); done; fi
      d=$((s - now + ${DH_SLACK:-60})); [ "$d" -gt 691200 ] && d=691200
      echo "$d"
    }
    """#
}
